;;; elisp-reader-tests.el --- Tests elisp-reader -*- lexical-binding: t -*-

;;; Commentary

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'elisp-reader)

(defun bc--if-result (result consequent alternative)
  "Call the appropriate function depending on the success of RESULT.
If RESULT is a cons, it passes the message to CONSEQUENT or ALTERNATIVE.
Otherwise it passes nil."
  (declare (indent defun))
  (if (consp result)
      (funcall (if (car result) consequent alternative) (cdr result))
    (funcall (if result consequent alternative) nil)))


(buttercup-define-matcher :read-results-to-be (string function &rest args)
  "Reads the provided STRING with both our reader and Emacs’ reader, comparing
the results with the provided FUNCTION."
  (cl-destructuring-bind ((str-expr . str) (fn-expr . fn))
      (mapcar #'buttercup--expr-and-value (list string function))
    (cl-destructuring-bind ((our-result . our-pos) (orig-result . orig-pos))
      (list (er-read-from-string str) (funcall er-*orig-read-from-string* str))
      (let ((result (apply fn (append args (list our-result orig-result)))))
        (bc--if-result
         (cons result
               (if result
                   "results should have differed"
                 (format "Expected %S to read %S, but ours resulted in %S, while the original was %S"
                         str-expr
                         fn-expr
                         our-result
                         orig-result)))
         (lambda (msg)
           (let ((pos-result (eql our-pos orig-pos)))
             (cons pos-result
                   (if pos-result
                       (format "Either %S or the reads should have ended at different positions (but both ended at %S)."
                               (or msg "results should have not matched")
                               our-pos)
                     (format "Results matched, but the reads ended at different positions: ours at %S and the original at %S."
                             our-pos
                             orig-pos)))))
         (lambda (msg) (when msg (cons nil msg))))))))

(describe "elisp-reader"
  (describe "reading"
    (it "reads strings" (expect "\"xyz\"" :read-results-to-be #'equal))
    (it "reads characters" (expect "?a" :read-results-to-be #'eql))
    (it "reads integers" (expect "123" :read-results-to-be #'eql))
    (it "reads symbols" (expect "foo" :read-results-to-be #'eq))
    (it "reads lists" (expect "(a b c)" :read-results-to-be #'equal))
    (it "skips comments" (expect ";; test comment\nq" :read-results-to-be #'eql))
    (it "reads quotes" (expect "'(a b c)" :read-results-to-be #'equal))
    (it "reads vectors" (expect "[x y z]" :read-results-to-be #'equal))
    (it "reads quasi-quotes" (expect "`(,(car '(x y z)))" :read-results-to-be #'equal))))

(provide 'elisp-reader-tests)
;;; elisp-reader-tests.el ends here
