;;; tmp.el --- testing elisp-reader  -*- lexical-binding: t; -*-

;; Local Variables:
;; read-symbol-shorthands: (("er-" . "elisp-reader-"))
;; End:

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'elisp-reader)

(defun er-test (buffer)
  "Check for diffs between reading BUFFER  with elisp-reader and the original."
  (with-current-buffer buffer
    (save-excursion
      (while (not (eobp))
        (skip-chars-forward " \t\n\r\f\xa0")
        (message "At: %d" (point))
        (when (not (eobp))
          (let ((ours (ignore-errors (save-excursion (er-read buffer))))
                (orig (ignore-errors (funcall er-*orig-read* buffer))))
            (unless (equal ours orig)
              (error "Found difference before %S\nOurs: %S\nShould be: %S"
                     (point) ours orig))))))))

(er-def-syntax ?{
               (lambda (in _ch)
                 (let ((list (er-read-list in ?} t)))
                   `(list ,@(cl-loop for (key val) on list by #'cddr
                                     collect `(cons ,key ,val))))))

(provide 'tmp)
;;; tmp.el ends here
