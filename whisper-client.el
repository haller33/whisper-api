;;; themes/whisper-client.el -*- lexical-binding: t; -*-
;;; whisper-client.el --- Async voice transcription via Whisper API -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Your Name

;; Author: Your Name <you@example.com>
;; Version: 0.3.0
;; Package-Requires: ((emacs "30") (transient "0.4") (seq "2.24"))
;; Keywords: convenience, multimedia, tools

;;; Commentary:
;; Cliente Emacs para API Whisper (gravação remota, upload, polling,
;; inserção por marcador, histórico SQLite, menu transient).

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

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar whisper-client-active-jobs (make-hash-table :test 'equal)
  "Hash table mapping job-id to a plist of (marker buffer timer).")

(defvar whisper-client-mode-line-string ""
  "Current mode-line indicator string.")

(defvar whisper-client-db-connection nil
  "SQLite connection to the history database.")

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
;; Async HTTP helpers (using url-retrieve with native JSON)
;; ----------------------------------------------------------------------

(defun whisper-client-url-parse-json (response)
  "Extract and parse JSON from an HTTP RESPONSE buffer.
Returns the parsed data as an alist (for objects) or vector (for arrays)."
  (with-current-buffer response
    (goto-char (point-min))
    (if (re-search-forward "\n\n" nil t)
        (let ((json-string (buffer-substring-no-properties (point) (point-max))))
          (ignore-errors (json-parse-string json-string :object-type 'alist)))
      nil)))

(defun whisper-client-api-post (endpoint data callback &optional error-callback)
  "Send a POST request to ENDPOINT with DATA (alist).
CALLBACK receives parsed JSON (alist or vector)."
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
                          ;; Se for um vetor (array) ou se for uma lista sem campo "error"
                          (if (and json-response
                                   (or (vectorp json-response)
                                       (not (assq 'error json-response))))
                              (funcall callback json-response)
                            (when error-callback
                              (funcall error-callback (format "API error: %s"
                                                              (or (cdr (assq 'error json-response))
                                                                  "unknown"))))))))
                  nil nil t)))

(defun whisper-client-api-get (endpoint callback &optional error-callback)
  "Send a GET request to ENDPOINT.
CALLBACK receives parsed JSON (alist or vector)."
  (let ((url (concat whisper-client-api-url endpoint)))
    (url-retrieve url
                  (lambda (status)
                    (let ((err (plist-get status :error)))
                      (if err
                          (when error-callback (funcall error-callback (format "Network error: %s" err)))
                        (let* ((response-buffer (current-buffer))
                               (json-response (whisper-client-url-parse-json response-buffer)))
                          (kill-buffer response-buffer)
                          (if (and json-response
                                   (or (vectorp json-response)
                                       (not (assq 'error json-response))))
                              (funcall callback json-response)
                            (when error-callback
                              (funcall error-callback (format "API error: %s"
                                                              (or (cdr (assq 'error json-response))
                                                                  "unknown"))))))))
                  nil nil t)))

;; ----------------------------------------------------------------------
;; Multipart upload for files (POST /upload)
;; ----------------------------------------------------------------------

(defun whisper-client-api-upload (endpoint file-path session-id callback &optional error-callback)
  "Upload a file using multipart/form-data to ENDPOINT.
FILE-PATH is the audio file. SESSION-ID is a string (may be empty).
CALLBACK receives parsed JSON response."
  (let* ((url (concat whisper-client-api-url endpoint))
         (boundary (format "WhisperEmacsBoundary%s" (md5 (format "%s" (current-time)))))
         (filename (file-name-nondirectory file-path))
         (file-content (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file-path)
                         (buffer-string)))
         (body (concat
                "--" boundary "\r\n"
                "Content-Disposition: form-data; name=\"session_id\"\r\n\r\n"
                (or session-id "") "\r\n"
                "--" boundary "\r\n"
                "Content-Disposition: form-data; name=\"file\"; filename=\"" filename "\"\r\n"
                "Content-Type: application/octet-stream\r\n\r\n"
                file-content "\r\n"
                "--" boundary "--\r\n")))
    (let ((url-request-method "POST")
          (url-request-extra-headers
           `(("Content-Type" . ,(concat "multipart/form-data; boundary=" boundary))
             ("Content-Length" . ,(number-to-string (string-bytes body)))))
          (url-request-data body))
      (url-retrieve url
                    (lambda (status)
                      (let ((err (plist-get status :error)))
                        (if err
                            (when error-callback (funcall error-callback (format "Network error: %s" err)))
                          (let* ((response-buffer (current-buffer))
                                 (json-response (whisper-client-url-parse-json response-buffer)))
                            (kill-buffer response-buffer)
                            (if (and json-response
                                     (or (vectorp json-response)
                                         (not (assq 'error json-response))))
                                (funcall callback json-response)
                              (when error-callback
                                (funcall error-callback (format "API error: %s"
                                                                (or (cdr (assq 'error json-response))
                                                                    "unknown"))))))))
                    nil nil t))))

;; ----------------------------------------------------------------------
;; Job polling and insertion
;; ----------------------------------------------------------------------

(defun whisper-client-insert-transcript (job-id transcript)
  "Insert TRANSCRIPT at the marker associated with JOB-ID."
  (let* ((job (gethash job-id whisper-client-active-jobs))
         (marker (plist-get job :marker))
         (buffer (plist-get job :buffer)))
    (if (and marker (buffer-live-p buffer))
        (with-current-buffer buffer
          (save-excursion
            (when (marker-position marker)
              (goto-char marker)
              (when whisper-client-insert-with-newlines
                (unless (bolp) (insert "\n")))
              (insert transcript)
              (when whisper-client-insert-with-newlines
                (unless (eolp) (insert "\n")))
              (message "[Whisper] Inserted transcript from job %s" job-id))))
      (message "[Whisper] Warning: buffer for job %s is dead, transcript not inserted." job-id))))

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
        (message "[Whisper] Transcription ready: %.60s" transcript)))
    (whisper-client-cleanup-job job-id)))

(defun whisper-client-poll-job (job-id)
  "Poll the status of JOB-ID asynchronously."
  (whisper-client-api-get (format "/job/%s" job-id)
                    (lambda (response)
                      (let ((status (cdr (assq 'status response))))
                        (cond ((string= status "completed")
                               (whisper-client-handle-job-completion job-id response))
                              ((string= status "failed")
                               (let ((error-msg (cdr (assq 'error response))))
                                 (message "[Whisper] Job %s failed: %s" job-id error-msg)
                                 (whisper-client-cleanup-job job-id)))
                              (t ; still pending/processing
                               (let ((timer (run-at-time whisper-client-poll-interval nil
                                                         #'whisper-client-poll-job job-id)))
                                 (let ((job (gethash job-id whisper-client-active-jobs)))
                                   (when job
                                     (puthash job-id (plist-put job :timer timer)
                                              whisper-client-active-jobs))))))))
                    (lambda (err)
                      (message "[Whisper] Polling error for %s: %s" job-id err)
                      (whisper-client-cleanup-job job-id))))

(defun whisper-client-cleanup-job (job-id)
  "Remove JOB-ID from active jobs and cancel its timer."
  (let ((job (gethash job-id whisper-client-active-jobs)))
    (when job
      (let ((timer (plist-get job :timer)))
        (when timer (cancel-timer timer)))
      (remhash job-id whisper-client-active-jobs)))
  (whisper-client-update-mode-line))

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
                               (puthash job-id (list :marker marker
                                                     :buffer current-buf
                                                     :timer nil)
                                        whisper-client-active-jobs)
                               (whisper-client-update-mode-line)
                               (message "[Whisper] Recording started, job %s" job-id)
                               (whisper-client-poll-job job-id)))))
                       (lambda (err)
                         (message "[Whisper] Failed to start recording: %s" err)))))

;; ----------------------------------------------------------------------
;; File upload command
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
                                 (puthash job-id (list :marker marker
                                                       :buffer current-buf
                                                       :timer nil)
                                          whisper-client-active-jobs)
                                 (whisper-client-update-mode-line)
                                 (message "[Whisper] Upload done, job %s" job-id)
                                 (whisper-client-poll-job job-id)))))
                         (lambda (err)
                           (message "[Whisper] Upload failed: %s" err)))))

;; ----------------------------------------------------------------------
;; Retry failed/pending jobs
;; ----------------------------------------------------------------------

(defun whisper-client-retry-job (job-id)
  "Retry a specific JOB-ID that is pending or failed.
Re‑uploads the audio file if it exists locally."
  (interactive (list (completing-read "Job ID to retry: "
                                      (mapcar (lambda (j) (cdr (assq 'job_id j)))
                                              (whisper-client-db-load-pending-failed))
                                      nil t)))
  (let ((job (seq-find (lambda (j) (string= (cdr (assq 'job_id j)) job-id))
                       (whisper-client-db-load-pending-failed))))
    (if (null job)
        (message "Job %s not found or not retriable." job-id)
      (let ((audio-hash (cdr (assq 'audio_hash job)))
            (session-id (cdr (assq 'session_id job))))
        ;; We need the original audio file path. The API server stores audio files
        ;; in its recordings directory. Without the file, we cannot retry.
        ;; For now, we just re‑poll the API – maybe the job was stuck.
        (message "Re‑polling job %s..." job-id)
        (whisper-client-poll-job job-id)))))

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
;; API inspection commands (health, queue, sessions, hash)
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

(defun whisper-client-cancel-current-job ()
  "Cancel the most recent active job (or ask for job-id if multiple)."
  (interactive)
  (let ((jobs (hash-table-keys whisper-client-active-jobs)))
    (if (null jobs)
        (message "No active jobs to cancel.")
      (let ((job-id (if (cdr jobs)
                        (completing-read "Cancel job: " jobs nil t)
                      (car jobs))))
        (whisper-client-cleanup-job job-id)
        (message "Job %s cancelled." job-id)))))

;; ----------------------------------------------------------------------
;; Transient menu (full-featured)
;; ----------------------------------------------------------------------

(transient-define-prefix whisper-client-transient ()
  "Transient menu for Whisper client."
  ["Recording & Upload"
   ("r" "Start recording" whisper-client-start-recording)
   ("u" "Upload audio file" whisper-client-upload-file)
   ("c" "Cancel current job" whisper-client-cancel-current-job)]
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

(provide 'whisper-client)

;;; whisper-client.el ends here
