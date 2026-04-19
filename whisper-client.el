;;; whisper-client.el --- Async voice transcription via Whisper API -*- lexical-binding: t; -*-

;; Copyright (C) 2026  haller33

;; Author: Your Name <you@example.com>
;; Version: 0.4.0
;; Package-Requires: ((emacs "30") (transient "0.4") (seq "2.24"))
;; Keywords: convenience, multimedia, tools

;;; Commentary:
;; Cliente Emacs para API Whisper (gravação remota, upload, polling,
;; inserção por marcador com animação, histórico SQLite, menu transient).

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'json)
(require 'sqlite)
(require 'transient)
(require 'seq)
(eval-when-compile (require 'subr-x))

;; ----------------------------------------------------------------------
;; Customizable variables
;; ----------------------------------------------------------------------

(defgroup whisper-client nil
  "Async voice transcription via Whisper API."
  :group 'multimedia
  :prefix "whisper-")

(defcustom whisper-client-api-url "http://localhost:8080"
  "Base URL of the Whisper API server."
  :type 'string
  :group 'whisper-client)

(defcustom whisper-client-default-duration 5
  "Default recording duration in seconds when none is provided."
  :type 'natnum
  :group 'whisper-client)

(defcustom whisper-client-poll-interval 2
  "Seconds between polling requests for job status."
  :type 'natnum
  :group 'whisper-client)

(defcustom whisper-client-session-id nil
  "Default session ID for recordings.
If nil, a session ID will be auto-generated from the current
buffer name and timestamp."
  :type '(choice (const :tag "Auto-generate" nil)
                 (string :tag "Fixed session ID"))
  :group 'whisper-client)

(defcustom whisper-client-db-file (locate-user-emacs-file "whisper-history.sqlite")
  "SQLite database file for storing transcription history."
  :type 'file
  :group 'whisper-client)

(defcustom whisper-client-status-buffer-name "*whisper-status*"
  "Name of the buffer used for status and log messages."
  :type 'string
  :group 'whisper-client)

(defcustom whisper-client-history-buffer-name "*whisper-history*"
  "Name of the buffer used to display transcription history."
  :type 'string
  :group 'whisper-client)

(defcustom whisper-client-notify-on-completion t
  "If non-nil, show a message when a transcription finishes."
  :type 'boolean
  :group 'whisper-client)

(defcustom whisper-client-insert-with-newlines t
  "If non-nil, insert a newline before and after the transcript."
  :type 'boolean
  :group 'whisper-client)

(defcustom whisper-client-spinner-interval 0.15
  "Seconds between spinner animation steps."
  :type 'float
  :group 'whisper-client)

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar whisper-client-active-jobs (make-hash-table :test 'equal)
  "Hash table mapping job-id to a plist of (marker buffer timer spinner-timer).")

(defvar whisper-client-mode-line-string ""
  "Current mode-line indicator string.")

(defvar whisper-client-db-connection nil
  "SQLite connection to the history database.")

;; Spinner characters
(defvar whisper-client-spinner-chars ["|" "/" "-" "\\"])
(defvar whisper-client-spinner-index 0)

;; ----------------------------------------------------------------------
;; Database initialization and helpers
;; ----------------------------------------------------------------------

(defun whisper-client-db-init ()
  "Initialize the SQLite database and create the history table if needed."
  (unless whisper-client-db-connection
    (setq whisper-client-db-connection (sqlite-open whisper-client-db-file))
    (sqlite-execute whisper-client-db-connection
                    "CREATE TABLE IF NOT EXISTS transcriptions (
                       id INTEGER PRIMARY KEY AUTOINCREMENT,
                       job_id TEXT UNIQUE NOT NULL,
                       session_id TEXT NOT NULL,
                       transcript TEXT,
                       language TEXT,
                       audio_hash TEXT,
                       status TEXT,
                       created_at TEXT,
                       inserted_at TEXT
                     )"))
  whisper-client-db-connection)

(defun whisper-client-db-save (job-id session-id transcript language audio-hash status)
  "Save a transcription record to the database."
  (let ((conn (whisper-client-db-init))
        (now (format-time-string "%Y-%m-%d %H:%M:%S")))
    (sqlite-execute conn
                    "INSERT OR REPLACE INTO transcriptions
                     (job_id, session_id, transcript, language, audio_hash, status, created_at, inserted_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                    (list job-id session-id transcript language audio-hash status now now))))

(defun whisper-client-db-load-history (&optional session-id)
  "Retrieve all transcriptions, optionally filtered by SESSION-ID.
Returns a list of plists."
  (let ((conn (whisper-client-db-init))
        (query "SELECT job_id, session_id, transcript, language, audio_hash, status, created_at FROM transcriptions"))
    (when session-id
      (setq query (concat query " WHERE session_id = ?")))
    (mapcar (lambda (row)
              `((job_id . ,(nth 0 row))
                (session_id . ,(nth 1 row))
                (transcript . ,(nth 2 row))
                (language . ,(nth 3 row))
                (audio_hash . ,(nth 4 row))
                (status . ,(nth 5 row))
                (created_at . ,(nth 6 row))))
            (if session-id
                (sqlite-select conn query (list session-id))
              (sqlite-select conn query)))))

(defun whisper-client-db-load-pending-failed ()
  "Retrieve jobs with status 'pending' or 'failed' from the local database.
Returns a list of plists."
  (let ((conn (whisper-client-db-init)))
    (mapcar (lambda (row)
              `((job_id . ,(nth 0 row))
                (session_id . ,(nth 1 row))
                (audio_hash . ,(nth 2 row))
                (status . ,(nth 3 row))
                (created_at . ,(nth 4 row))))
            (sqlite-select conn
                           "SELECT job_id, session_id, audio_hash, status, created_at
                            FROM transcriptions
                            WHERE status IN ('pending', 'failed')"))))

;; ----------------------------------------------------------------------
;; Async HTTP helpers (corrigidos para tratar :null como sucesso)
;; ----------------------------------------------------------------------

(defun whisper-client-url-parse-json (response)
  "Extract and parse JSON from an HTTP RESPONSE buffer."
  (with-current-buffer response
    (goto-char (point-min))
    (if (re-search-forward "\n\n" nil t)
        (let ((json-string (buffer-substring-no-properties (point) (point-max))))
          (ignore-errors (json-parse-string json-string :object-type 'alist)))
      nil)))

(defun whisper-client--is-error-response (response)
  "Return non-nil if RESPONSE is an alist containing a non-null `error' field."
  (and (consp response)
       (not (vectorp response))
       (let ((err (cdr (assq 'error response))))
         (and err (not (eq err :null))))))

(defun whisper-client-api-get (endpoint callback &optional error-callback)
  "Send a GET request to ENDPOINT."
  (let ((url (concat whisper-client-api-url endpoint)))
    (url-retrieve url
                  (lambda (status)
                    (let ((err (plist-get status :error)))
                      (if err
                          (when error-callback (funcall error-callback (format "Network error: %s" err)))
                        (let* ((response-buffer (current-buffer))
                               (json-response (whisper-client-url-parse-json response-buffer)))
                          (kill-buffer response-buffer)
                          (if (whisper-client--is-error-response json-response)
                              (when error-callback
                                (funcall error-callback (format "API error: %s" (cdr (assq 'error json-response)))))
                            (funcall callback json-response))))))
                  nil nil t)))

(defun whisper-client-api-post (endpoint data callback &optional error-callback)
  "Send a POST request to ENDPOINT with DATA (alist)."
  (let* ((url (concat whisper-client-api-url endpoint))
         (json-data (encode-coding-string (json-serialize data) 'utf-8))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data json-data))
    (url-retrieve url
                  (lambda (status)
                    (let ((err (plist-get status :error)))
                      (if err
                          (when error-callback (funcall error-callback (format "Network error: %s" err)))
                        (let* ((response-buffer (current-buffer))
                               (json-response (whisper-client-url-parse-json response-buffer)))
                          (kill-buffer response-buffer)
                          (if (whisper-client--is-error-response json-response)
                              (when error-callback
                                (funcall error-callback (format "API error: %s" (cdr (assq 'error json-response)))))
                            (funcall callback json-response))))))
                  nil nil t)))

;; ----------------------------------------------------------------------
;; Spinner overlay management (fixed)
;; ----------------------------------------------------------------------

(defun whisper-client-create-spinner (marker)
  "Create an overlay at MARKER that will hold the spinner animation."
  (let ((overlay (make-overlay marker marker)))
    (overlay-put overlay 'face '(:foreground "cyan" :weight bold))
    (overlay-put overlay 'whisper-spinner t)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'before-string "| ")
    overlay))

(defun whisper-client-start-spinner-timer (job-id)
  "Start the spinner animation timer for JOB-ID."
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      ;; Cancel any existing timer first
      (let ((old-timer (plist-get job :spinner-timer)))
        (when old-timer (cancel-timer old-timer)))
      (let ((timer (run-at-time 0 whisper-client-spinner-interval
                                #'whisper-client-update-spinner job-id)))
        (puthash job-id (plist-put job :spinner-timer timer)
                 whisper-client-active-jobs)))))

(defun whisper-client-update-spinner (job-id)
  "Cycle spinner characters for JOB-ID."
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      (let* ((overlay (plist-get job :spinner-overlay))
             (buffer (plist-get job :buffer))
             (idx (or (plist-get job :spinner-idx) 0))
             (next-idx (mod (1+ idx) (length whisper-client-spinner-chars)))
             (char (aref whisper-client-spinner-chars idx)))
        (when (and overlay (overlayp overlay) (buffer-live-p buffer))
          (with-current-buffer buffer
            (overlay-put overlay 'before-string (concat char " "))
            (puthash job-id (plist-put job :spinner-idx next-idx)
                     whisper-client-active-jobs)))))))

(defun whisper-client-remove-spinner (job-id)
  "Remove spinner overlay and cancel timer for JOB-ID."
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      (let ((overlay (plist-get job :spinner-overlay))
            (timer (plist-get job :spinner-timer)))
        (when timer (cancel-timer timer))
        (when (and overlay (overlayp overlay))
          (delete-overlay overlay))
        (puthash job-id (plist-put (plist-put job :spinner-overlay nil) :spinner-timer nil)
                 whisper-client-active-jobs)))))

(defun whisper-client-cleanup-job (job-id)
  "Remove JOB-ID from active jobs, cancel timers and remove spinner."
  (whisper-client-remove-spinner job-id)   ; <-- added
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      (let ((timer (plist-get job :timer)))
        (when timer (cancel-timer timer))))
    (remhash job-id whisper-client-active-jobs))
  (whisper-client-update-mode-line))

(defun whisper-client-notify (title message)
  "Send a desktop notification with TITLE and MESSAGE."
  (cond ((executable-find "notify-send")
         (call-process "notify-send" nil 0 nil title message))
        ((executable-find "osascript") ; macOS
         (call-process "osascript" nil 0 nil
                       "-e" (format "display notification \"%s\" with title \"%s\"" message title)))
        (t (message "[Whisper] %s: %s" title message))))

;; Then inside `whisper-client-handle-job-completion`, after inserting:
;(when whisper-client-notify-on-completion
;  (whisper-client-notify "Whisper" (format "Transcription ready: %.60s" transcript)))

;; ----------------------------------------------------------------------
;; Job polling and insertion (com spinner)
;; ----------------------------------------------------------------------

(defun whisper-client-insert-transcript (job-id transcript)
  "Insert TRANSCRIPT at the marker associated with JOB-ID.
Handles read-only buffers temporarily."
  (let* ((job (gethash job-id whisper-client-active-jobs))
         (marker (plist-get job :marker))
         (buffer (plist-get job :buffer)))
    (if (and marker (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))  ; allow insertion even in read-only buffers
            (save-excursion
              (when (marker-position marker)
                (goto-char marker)
                (when whisper-client-insert-with-newlines
                  (unless (bolp) (insert "\n")))
                (insert transcript)
                (when whisper-client-insert-with-newlines
                  (unless (eolp) (insert "\n")))
                (message "[Whisper] Inserted transcript from job %s" job-id))))))
    (whisper-client-remove-spinner job-id)))

(defun whisper-client-handle-job-completion (job-id response)
  "Handle a completed job RESPONSE for JOB-ID."
  (let* ((transcript (cdr (assq 'transcript response)))
         (language (cdr (assq 'language response)))
         (audio-hash (cdr (assq 'audio_hash response)))
         (session-id (cdr (assq 'session_id response)))
         (status (cdr (assq 'status response))))
    (when transcript
      (whisper-client-insert-transcript job-id transcript)
      (whisper-client-db-save job-id session-id transcript language audio-hash status)
      (when whisper-client-notify-on-completion
        (message "[Whisper] Transcription ready: %.60s" transcript)
        (whisper-client-notify "Whisper" (format "Transcription ready: %.60s" transcript))))

    (whisper-client-cleanup-job job-id)))

(defun whisper-client-poll-job (job-id)
  "Poll the status of JOB-ID asynchronously."
  (whisper-client-api-get (format "/job/%s" job-id)
                    (lambda (response)
                      (if (not (and (consp response) (not (vectorp response))))
                          ;; Resposta não é um alist (ex.: :null) → re-poll
                          (let ((timer (run-at-time whisper-client-poll-interval nil
                                                    #'whisper-client-poll-job job-id)))
                            (let ((job (gethash job-id whisper-client-active-jobs)))
                              (when job
                                (puthash job-id (plist-put job :timer timer)
                                         whisper-client-active-jobs))))
                        ;; Resposta é um alist válido
                        (whisper-client-notify "Whisper" "Polling job")
                        (let ((status (cdr (assq 'status response))))
                          (cond ((string= status "completed")
                                 (whisper-client-handle-job-completion job-id response))
                                ((string= status "failed")
                                 (message "[Whisper] Job %s failed: %s" job-id (cdr (assq 'error response)))
                                 (whisper-client-cleanup-job job-id))
                                (t ; pending/processing
                                 (let ((timer (run-at-time whisper-client-poll-interval nil
                                                           #'whisper-client-poll-job job-id)))
                                   (let ((job (gethash job-id whisper-client-active-jobs)))
                                     (when job
                                       (puthash job-id (plist-put job :timer timer)
                                                whisper-client-active-jobs)))))))))
                    (lambda (err)
                      (message "[Whisper] Polling error for %s: %s" job-id err)
                      (whisper-client-cleanup-job job-id))))

(defun whisper-client-cleanup-job (job-id)
  "Remove JOB-ID from active jobs, cancel timers and remove spinner."
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      (let ((timer (plist-get job :timer))
            (spinner-timer (plist-get job :spinner-timer))
            (overlay (plist-get job :spinner-overlay)))
        (when timer (cancel-timer timer))
        (when spinner-timer (cancel-timer spinner-timer))
        (when (and overlay (overlayp overlay)) (delete-overlay overlay))
        (remhash job-id whisper-client-active-jobs)))
  (whisper-client-update-mode-line)))

(defun whisper-client-start-recording (duration &optional session-id)
  "Start a remote recording of DURATION seconds.
Optional SESSION-ID overrides `whisper-client-session-id'."
  (interactive (list (read-number "Duration (seconds): " whisper-client-default-duration)))
  (let ((sid (or session-id whisper-client-session-id
                 (format "emacs-%s-%s"
                         (buffer-name)
                         (format-time-string "%Y%m%d-%H%M%S")))))
    (whisper-client-api-post "/record"
                       `((duration . ,duration) (session_id . ,sid))
                       (lambda (response)
                         (let ((job-id (cdr (assq 'job_id response)))
                               (current-buf (current-buffer))
                               (current-point (point)))
                           (when job-id
                             (let ((marker (make-marker)))
                               (set-marker marker current-point current-buf)
                               ;; Create spinner overlay
                               (let ((overlay (whisper-client-create-spinner marker)))
                                 (puthash job-id (list :marker marker
                                                       :buffer current-buf
                                                       :timer nil
                                                       :spinner-overlay overlay
                                                       :spinner-timer nil)
                                          whisper-client-active-jobs)
                                 (whisper-client-start-spinner-timer job-id))
                               (whisper-client-update-mode-line)
                               (message "[Whisper] Recording started, job %s" job-id)
                               (whisper-client-poll-job job-id)))))
                       (lambda (err)
                         (message "[Whisper] Failed to start recording: %s" err)))))

;; ----------------------------------------------------------------------
;; File upload command (com spinner)
;; ----------------------------------------------------------------------

(defun whisper-client-upload-file (file &optional session-id)
  "Upload an audio FILE for transcription.
Optional SESSION-ID overrides `whisper-client-session-id'."
  (interactive (list (read-file-name "Audio file: ")
                     (read-string "Session ID (optional): " nil nil whisper-client-session-id)))
  (let ((sid (if (string-empty-p session-id)
                 (format "emacs-upload-%s" (format-time-string "%Y%m%d%H%M%S"))
               session-id)))
    (message "[Whisper] Uploading %s..." (file-name-nondirectory file))
    (whisper-client-api-upload "/upload" file sid
                         (lambda (response)
                           (let ((job-id (cdr (assq 'job_id response)))
                                 (current-buf (current-buffer))
                                 (current-point (point)))
                             (when job-id
                               (let ((marker (make-marker)))
                                 (set-marker marker current-point current-buf)
                                 (let ((overlay (whisper-client-create-spinner marker)))
                                   (puthash job-id (list :marker marker
                                                         :buffer current-buf
                                                         :timer nil
                                                         :spinner-overlay overlay
                                                         :spinner-timer nil)
                                            whisper-client-active-jobs)
                                   (whisper-client-start-spinner-timer job-id))
                                 (whisper-client-update-mode-line)
                                 (message "[Whisper] Upload done, job %s" job-id)
                                 (whisper-client-poll-job job-id)))))
                         (lambda (err)
                           (message "[Whisper] Upload failed: %s" err)))))

;; ----------------------------------------------------------------------
;; List active jobs and cancel
;; ----------------------------------------------------------------------

(defun whisper-client-list-active-jobs ()
  "Display a buffer listing all active jobs with options to cancel."
  (interactive)
  (let ((buf (get-buffer-create "*Whisper Active Jobs*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "=== Active Whisper Jobs ===\n\n")
      (if (= (hash-table-count whisper-client-active-jobs) 0)
          (insert "No active jobs.\n")
        (maphash (lambda (job-id job)
                   (let ((marker (plist-get job :marker))
                         (buffer (plist-get job :buffer))
                         (pos (if marker (marker-position marker) "unknown")))
                     (insert (format "Job ID: %s\n  Buffer: %s, Position: %s\n"
                                     job-id buffer pos))
                     (insert-button "[Cancel]"
                                    'action (lambda (btn)
                                              (let ((job-id (button-get btn 'job-id)))
                                                (whisper-client-cancel-job-by-id job-id)))
                                    'job-id job-id)
                     (insert "\n\n")))
                 whisper-client-active-jobs))
      (insert "\nPress `q' to quit, `C-c C-c' to refresh.\n")
      (goto-char (point-min)))
    (display-buffer buf)
    (with-current-buffer buf
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "q") #'quit-window)
        (define-key map (kbd "C-c C-c") #'whisper-client-list-active-jobs)
        (use-local-map map)))))

(defun whisper-client-cancel-job-by-id (job-id)
  "Cancel the active job with JOB-ID."
  (interactive (list (completing-read "Job ID to cancel: "
                                      (hash-table-keys whisper-client-active-jobs)
                                      nil t)))
  (if (gethash job-id whisper-client-active-jobs)
      (progn
        (whisper-client-cleanup-job job-id)
        (message "Job %s cancelled." job-id)
        (whisper-client-list-active-jobs)) ; refresh list
    (message "Job %s not found." job-id)))

(defun whisper-client-cancel-current-job ()
  "Cancel the most recent active job (or ask for job-id if multiple)."
  (interactive)
  (let ((jobs (hash-table-keys whisper-client-active-jobs)))
    (if (null jobs)
        (message "No active jobs to cancel.")
      (let ((job-id (if (cdr jobs)
                        (completing-read "Cancel job: " jobs nil t)
                      (car jobs))))
        (whisper-client-cancel-job-by-id job-id)))))

;; ----------------------------------------------------------------------
;; Retry failed/pending jobs
;; ----------------------------------------------------------------------

(defun whisper-client-retry-job (job-id)
  "Retry a specific JOB-ID that is pending or failed."
  (interactive (list (completing-read "Job ID to retry: "
                                      (mapcar (lambda (j) (cdr (assq 'job_id j)))
                                              (whisper-client-db-load-pending-failed))
                                      nil t)))
  (let ((job (seq-find (lambda (j) (string= (cdr (assq 'job_id j)) job-id))
                       (whisper-client-db-load-pending-failed))))
    (if (null job)
        (message "Job %s not found or not retriable." job-id)
      (message "Re‑polling job %s..." job-id)
      (whisper-client-poll-job job-id))))

(defun whisper-client-retry-failed-jobs ()
  "Retry all failed or pending jobs from the local database."
  (interactive)
  (let ((jobs (whisper-client-db-load-pending-failed)))
    (if (null jobs)
        (message "No pending or failed jobs found.")
      (dolist (job jobs)
        (let ((job-id (cdr (assq 'job_id job))))
          (message "Retrying job %s..." job-id)
          (whisper-client-poll-job job-id))))))

;; ----------------------------------------------------------------------
;; API inspection commands
;; ----------------------------------------------------------------------

(defun whisper-client-system-status ()
  "Check API health and queue size, display in echo area."
  (interactive)
  (whisper-client-api-get "/health"
                    (lambda (health)
                      (whisper-client-api-get "/queue"
                                        (lambda (queue)
                                          (message "[Whisper] API: %s | Model: %s | Queue size: %d"
                                                   (cdr (assq 'status health))
                                                   (cdr (assq 'model health))
                                                   (cdr (assq 'pending_jobs queue))))))
                    (lambda (err) (message "[Whisper] Health check failed: %s" err))))

(defun whisper-client-query-hash (hash)
  "Look up a transcription by its audio HASH and display result."
  (interactive "sAudio hash: ")
  (whisper-client-api-get (format "/message?hash=%s" hash)
                    (lambda (response)
                      (with-output-to-temp-buffer "*Whisper Hash Result*"
                        (princ (format "Job ID: %s\nStatus: %s\nCreated: %s\n\nTranscript:\n%s"
                                       (cdr (assq 'job_id response))
                                       (cdr (assq 'status response))
                                       (cdr (assq 'created_at response))
                                       (or (cdr (assq 'transcript response)) "<no transcript>")))))
                    (lambda (err) (message "Hash not found: %s" err))))

(defun whisper-client-list-remote-sessions ()
  "List remote sessions from the API and show messages for selected session."
  (interactive)
  (whisper-client-api-get "/sessions"
                    (lambda (response)
                      (if (and (vectorp response) (= (length response) 0))
                          (message "No remote sessions found.")
                        (let* ((sessions (if (vectorp response) (append response nil) response))
                               (choice (completing-read "Select session: " sessions)))
                          (whisper-client-api-get (format "/messages?session=%s" choice)
                                            (lambda (msgs)
                                              (with-output-to-temp-buffer "*Whisper Remote Session*"
                                                (princ (format "=== Messages for session: %s ===\n\n" choice))
                                                (dolist (m (if (vectorp msgs) (append msgs nil) msgs))
                                                  (princ (format "[%s] Job: %s | Status: %s\n%s\n\n"
                                                                 (cdr (assq 'created_at m))
                                                                 (cdr (assq 'job_id m))
                                                                 (cdr (assq 'status m))
                                                                 (or (cdr (assq 'transcript m)) "<processing>"))))))))))
                    (lambda (err) (message "Failed to list sessions: %s" err))))

;; ----------------------------------------------------------------------
;; Mode-line indicator
;; ----------------------------------------------------------------------

(defun whisper-client-update-mode-line ()
  "Update the mode-line string with current job count."
  (let ((count (hash-table-count whisper-client-active-jobs)))
    (setq whisper-client-mode-line-string
          (if (> count 0)
              (format " Whisper[%d]" count)
            ""))
    (force-mode-line-update t)))

;; ----------------------------------------------------------------------
;; Status and history buffers
;; ----------------------------------------------------------------------

(defun whisper-client-show-status-buffer ()
  "Display a buffer showing active jobs and recent completions from DB."
  (interactive)
  (let ((buf (get-buffer-create whisper-client-status-buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      (insert "=== Active Whisper Jobs ===\n\n")
      (if (> (hash-table-count whisper-client-active-jobs) 0)
          (maphash (lambda (job-id job)
                     (let ((marker (plist-get job :marker))
                           (buffer (plist-get job :buffer)))
                       (insert (format "Job: %s\n  Buffer: %s, Position: %s\n\n"
                                       job-id buffer (and marker (marker-position marker))))))
                   whisper-client-active-jobs)
        (insert "No active jobs.\n"))
      (insert "\n=== Recent Completions (last 5 from DB) ===\n\n")
      (let* ((history (whisper-client-db-load-history))
             (recent (seq-take history 5)))
        (dolist (rec recent)
          (insert (format "Job: %s\nSession: %s\nText: %.80s\n---\n"
                          (cdr (assq 'job_id rec))
                          (cdr (assq 'session_id rec))
                          (or (cdr (assq 'transcript rec)) "")))))
      (display-buffer buf))))

(defun whisper-client-show-history (&optional session-id)
  "Show local SQLite transcription history, optionally filtered by SESSION-ID.
With prefix argument, prompt for session ID."
  (interactive (list (when current-prefix-arg
                       (read-string "Session ID: " nil nil whisper-client-session-id))))
  (let* ((sid (or session-id whisper-client-session-id))
         (records (whisper-client-db-load-history sid))
         (buf (get-buffer-create whisper-client-history-buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "Whisper Transcription History%s\n\n"
                      (if sid (format " (session: %s)" sid) "")))
      (if (null records)
          (insert "No records found.\n")
        (dolist (rec records)
          (insert (format "Job ID: %s\nSession: %s\nStatus: %s\nCreated: %s\nText:\n%s\n\n"
                          (cdr (assq 'job_id rec))
                          (cdr (assq 'session_id rec))
                          (cdr (assq 'status rec))
                          (cdr (assq 'created_at rec))
                          (or (cdr (assq 'transcript rec)) "<no transcript>"))))))
    (display-buffer buf)))

;; ----------------------------------------------------------------------
;; Transient menu (full-featured)
;; ----------------------------------------------------------------------

(transient-define-prefix whisper-client-transient ()
  "Transient menu for Whisper client."
  ["Recording & Upload"
   ("r" "Start recording" whisper-client-start-recording)
   ("u" "Upload audio file" whisper-client-upload-file)
   ("c" "Cancel current job" whisper-client-cancel-current-job)
   ("a" "List active jobs" whisper-client-list-active-jobs)]
  ["Retry"
   ("R" "Retry failed/pending jobs" whisper-client-retry-failed-jobs)]
  ["Remote Queries"
   ("s" "List remote sessions" whisper-client-list-remote-sessions)
   ("h" "Query by hash" whisper-client-query-hash)]
  ["Local & Status"
   ("i" "API health / queue" whisper-client-system-status)
   ("l" "Local history (SQLite)" whisper-client-show-history)
   ("b" "Status buffer" whisper-client-show-status-buffer)]
  ["Settings"
   ("d" "Set default duration"
    (lambda () (interactive)
      (setq whisper-client-default-duration
            (read-number "Duration (seconds): " whisper-client-default-duration))))
   ("a" "Set API URL"
    (lambda () (interactive)
      (setq whisper-client-api-url
            (read-string "API URL: " whisper-client-api-url))))])

;; ----------------------------------------------------------------------
;; Minor mode definition
;; ----------------------------------------------------------------------

(defvar whisper-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c w r") #'whisper-client-start-recording)
    (define-key map (kbd "C-c w u") #'whisper-client-upload-file)
    (define-key map (kbd "C-c w s") #'whisper-client-show-status-buffer)
    (define-key map (kbd "C-c w h") #'whisper-client-show-history)
    (define-key map (kbd "C-c w c") #'whisper-client-cancel-current-job)
    (define-key map (kbd "C-c w a") #'whisper-client-list-active-jobs)
    (define-key map (kbd "C-c w t") #'whisper-client-transient)
    (define-key map (kbd "C-c w i") #'whisper-client-system-status)
    (define-key map (kbd "C-c w q") #'whisper-client-query-hash)
    (define-key map (kbd "C-c w l") #'whisper-client-list-remote-sessions)
    (define-key map (kbd "C-c w R") #'whisper-client-retry-failed-jobs)
    map)
  "Keymap for `whisper-client-mode'.")

;;;###autoload
(define-minor-mode whisper-client-mode
  "Minor mode for asynchronous voice transcription via Whisper API."
  :lighter (:eval whisper-client-mode-line-string)
  :keymap whisper-client-mode-map
  :global t
  (if whisper-client-mode
      (progn
        (whisper-client-db-init)
        (add-hook 'kill-emacs-hook #'whisper-client-cleanup-all-jobs)
        (message "Whisper client mode enabled"))
    (remove-hook 'kill-emacs-hook #'whisper-client-cleanup-all-jobs)
    (whisper-client-cleanup-all-jobs)
    (message "Whisper client mode disabled")))

(defun whisper-client-cleanup-all-jobs ()
  "Cancel all active jobs and timers."
  (maphash (lambda (job-id _) (whisper-client-cleanup-job job-id))
           whisper-client-active-jobs))

;; ----------------------------------------------------------------------
;; Provide the package
;; ----------------------------------------------------------------------

(provide 'whisper-client)

;;; whisper-client.el ends here
