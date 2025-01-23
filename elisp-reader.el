;;; elisp-reader.el --- A customizable Lisp reader -*- lexical-binding: t -*-

;; Local Variables:
;; read-symbol-shorthands: (("er-" . "elisp-reader-"))
;; End:

;; Copyright (C) 2016 Mihai Bazon

;; Author: Mihai Bazon <mihai.bazon@gmail.com>
;; Keywords: languages
;; Package-Requires: ((emacs "24.3"))
;; URL: https://github.com/mishoo/elisp-reader.el
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This replaces Elisp's `read' function, which is implemented in C,
;; with one implemented in Elisp which supports customizable syntax.
;; The way it does this is quite unorthodox -- it implements a rather
;; complete Elisp reader, but we do fall back to the original reader
;; for certain cases (like literal strings, characters, and other
;; syntax which the original reader supports but appears to be
;; internal to Emacs itself, such as byte-compiled code).
;;
;; It works nicely, if a bit slow.  To make it much faster you should
;; byte-compile this file:
;;
;;    "emacs --batch --eval '(byte-compile-file "elisp-reader.el")'"
;;
;; After loading this file, everything you eval with C-M-x in an Emacs
;; Lisp buffer, or via M-: or via M-x `eval-region' or in the REPL,
;; and even .el files loaded with `load', will be fed into our reader,
;; which will produce the actual AST to be evaluated.
;;
;; REGEXPS, PEOPLE!
;; ----------------
;;
;; One syntax extension it has built-in is for "literal regexps".  For
;; example, in the Elisp REPL (M-x `ielm'):
;;
;;     ELISP> #/(foo|bar)/
;;     "\\(foo\\|bar\\)"
;;
;; You get back a string with the Elisp regexp, nicely backslashed by
;; the rules that everybody and their uncle hate.  More examples:
;;
;;     ELISP> #/foo\nbar/
;;     "foo\nbar"             ;; literal newline
;;     ELISP> #/foo\(bar\)/
;;     "foo(bar)"             ;; match literal parens
;;     ELISP> #/\.elc$/
;;     "\\.elc$"              ;; a single \ to quote the dot
;;
;; Note that these are still Emacs (not Perl) regexes, with this small
;; twist: (1) grouping characters need not be backslashed and (2) you
;; write the regexp "literally", as opposed to inside a string, so you
;; don't need a ridiculous number of backslashes and guesswork to get
;; it right.  See `er-read-regexp'.
;;
;; DEFINING CUSTOM READER SYNTAX
;; -----------------------------
;;
;; Example of defining custom syntax (note this function uses
;; `er-read-list', which see, to get a list of Lisp datums):
;;
;;     (er-def-syntax ?{
;;       (lambda (in ch)
;;         (let ((list (er-read-list in ?} t)))
;;           `(list ,@(cl-loop for (key val) on list by #'cddr
;;                             collect `(cons ,key ,val))))))
;;
;; and now you can type into the REPL:
;;
;;     ELISP> { :foo 1 :bar "string" :baz (+ 2 3) }
;;     ((:foo . 1)
;;      (:bar . "string")
;;      (:baz . 5))
;;
;; That's a less parenthesized way to write an alist.  Just an
;; example, it's not that I'd recommend that.  In fact, the famous
;; words come to mind: "if you ever actually do this, then.. WAT!"
;;
;; The problem with writing your own syntax extensions is that for the
;; time being, they're GLOBAL.  That's even worse than unprefixed
;; global variables.  Until we figure out how to/and implement
;; something similar to Common Lisp's "named-readtables" [1], YOU
;; SHOULD NOT USE THIS PACKAGE, except perhaps for the regexp syntax.
;;
;; [1] https://common-lisp.net/project/named-readtables/
;;
;; FILE-LOCAL SYMBOLS
;; ------------------
;;
;; An `er-local' macro is provided which allows you to declare a list of
;; names to be kept "internal" to the current file.  Example:
;;
;;     (er-local "my-package" ("foo" "bar"))
;;
;; After this declaration, you can use freely foo and bar in the
;; current file:
;;
;;     (defun foo () ...)
;;     (defvar bar ...)
;;
;; In other files, or in the REPL, they are accessible as
;; my-package-foo and my-package-bar.  But if you place the same
;; `er-local' declaration in another file, they'd be auto-prefixed as
;; well so you can refer to them just as foo and bar.  This is a poor
;; man's package system.
;;
;; See the docstring of `er-local' for more information.
;;
;; Another idea I was thinking about (did not do it but it's trivial)
;; is to support some special character, say $ — if some symbol is
;; prefixed with $ then make sure it's "local" by default (by giving
;; it some name that can't be easily accessed from other file).  That
;; would make it possible for two different libraries to use a symbol
;; named $foo without conflict.

;;; Code:

(require 'cl-lib)

(defvar er-*orig-read* (symbol-function #'read)
  "Remember the original `read' function.
We'll have to use it in some situations that can't be handled from Lisp code.")

(defvar er-*orig-read-from-string* (symbol-function #'read-from-string)
  "Remember the original `read' function.
We'll have to use it in some situations that can't be handled from Lisp code.")

(defvar er-*macro-chars* (make-hash-table :test 'eq)
  "Custom read functions.
A hash that maps character to a function of two arguments, stream (as a
function) and character.  This function should return the AST that has been
read.  See usage of `er-def-syntax' later on.")

(defvar er-*read-filename* nil
  "The name of the file (or buffer) currently being parsed.
This dynamic variable will be bound by our read functions while parsing is in
progress.  It'll contain the value of `load-file-name', or the name of the
current buffer if it doesn't have an associated file.")

(defun er-make-stream (in)
  "Return the input stream IN as a function of one optional argument.
IN can be a buffer, a marker, a string, a function, or t or nil--see Elisp docs.
When called with no arguments, this function should return the next character
from the stream.  When called with a non-nil argument (character), this function
should arrange that character to be returned on next invokation with no
arguments.

The Elisp docs aren't entirely clear about this, but the closures
returned by this function will be able to push back multiple
characters.  Also, when the input argument is a string, the
produced function will support a keyword :pos argument, which
when passed it will return the current (zero-based) position of
the stream.  Example:

  (let ((stream (er-make-stream \"foo\")))
    (message \"%c%c\" (funcall stream) (funcall stream))  ;; fo
    (message \"%d\" (funcall stream :pos)))               ;; 2

This helps us implement `read-from-string', which has to return
the position of the stream."
  (let ((unget nil))
    (when (symbolp in)
      (setq in (symbol-function in)))
    (cond
     ((bufferp in) (lambda (&optional ch)
                     (with-current-buffer in
                       (cond
                        (ch (push ch unget))
                        (unget (pop unget))
                        (t
                         (when (not (eobp))
                           (prog1 (char-after)
                             (forward-char 1))))))))
     ((markerp in) (lambda (&optional ch)
                     (with-current-buffer (marker-buffer in)
                       (cond
                        (ch (push ch unget))
                        (unget (pop unget))
                        (t
                         (when (< (marker-position in) (point-max))
                           (prog1 (char-after in)
                             (move-marker in
                                          (1+ (marker-position in))
                                          (marker-buffer in)))))))))
     ((stringp in) (let ((pos 0))
                     (lambda (&optional ch)
                       (cond
                        ((eq ch :pos)
                         (if (< pos (length in))
                             (- pos 1)
                           pos))
                        (ch (push ch unget))
                        (unget (pop unget))
                        ((< pos (length in))
                         (prog1 (aref in pos)
                           (setq pos (1+ pos))))))))
     ((functionp in) (lambda (&optional ch)
                       (cond
                        (ch (push ch unget))
                        (unget (pop unget))
                        (t (funcall in)))))
     (t
      (read-string "Lisp expression:")))))

(defun er-orig-read ()
  "Call the original (low-level C) `read'.
This function should be invoked only within the dynamic extent of some `read' or
`read-from-string' execution."
  (funcall er-*orig-read* '%er-reader-insym))

(defun er-peek (in)
  "Return the next character without dropping it from the IN stream."
  (let ((ch (funcall in)))
    (funcall in ch)
    ch))

(defun er-next (in)
  "Return and discard the next character from the IN stream function."
  (funcall in))

(defun er-read-while (in pred)
  "Read characters from the input stream, IN, until PRED is nil.
Return a string containing the read characters."
  (let ((chars (list)) ch)
    (while (and (setq ch (er-peek in))
                (funcall pred ch))
      (push (er-next in) chars))
    (apply #'string (nreverse chars))))

(defun er-croak (msg &rest args)
  "Error with message MSG applied to ARGS in case of parse error."
  (if args
      (apply #'error msg args)
    (error "%s" msg)))

(defun er-read-string ()
  "Read a string from the current stream.
It defers to `er-orig-read' and thus this should only be called within the
dynamic extent of some `read' function."
  (er-orig-read))

(defun er-read-char ()
  "Read a character from the current stream.
It defers to `er-orig-read' and thus this should only be called within the
dynamic extent of some `read' function."
  (er-orig-read))

(defun er-letter? (ch)
  "Test whether the given character, CH, is a Unicode letter."
  (memq (get-char-code-property ch 'general-category)
        '(Ll Lu Lo Lt Lm Mn Mc Me Nl)))

(defun er-whitespace? (ch)
  "Test if the given character, CH, is whitespace.
\(XXX actually not all Unicode whitespace chars are handled; I'm not even sure
that would be correct)."
  (memq ch '(?  ?\t ?\n ?\f ?\r #xa0)))

(defun er-digit? (ch)
  "Test if the given character, CH,  is a plain digit."
  (<= ?0 ch ?9))

(defun er-number? (str)
  "Test if the given string, STR, should be interpreted as number."
  (string-match
   "^[-+]?\\(?:\\(?:[0-9]+\\|[0-9]*\\.[0-9]+\\)\\(?:[E|e][+|-]?[0-9]+\\)?\\)$"
   str))

(defun er-skip-whitespace (in)
  "Skip whitespace in the IN stream."
  (er-read-while in #'er-whitespace?))

(defun er-read-symbol-name (in)
  "Read and return the name of a symbol from the stream IN."
  (er-read-while in (lambda (ch)
                      (cond
                       ((eq ch ?\\)
                        (er-next in)
                        (if (er-peek in) t (er-croak "Unterminated input")))
                       (t
                        (or (er-letter? ch)
                            (er-digit? ch)
                            (memq ch '( ?- ?+ ?= ?* ?/ ?_ ?~ ?! ?@ ?. ?\|
                                        ?$ ?% ?^ ?& ?: ?< ?> ?{ ?} ?\?))))))))

(defun er-read-integer (in)
  "Read and return an integer.
\(NIL if there is no integer at current position in the IN stream)."
  (let ((num (er-read-while in #'er-digit?)))
    (when (< 0 (length num))
      (string-to-number num))))

(defun er-skip-comment (in)
  "Skip over a comment (move to end-of-line) in the IN stream."
  (er-read-while in (lambda (ch)
                      (not (eq ch ?\n)))))

(defun er-read-symbol (in)
  "Read a symbol or a number.
If what follows in the stream IN looks like a number, a number will be
returned (via the original reader).  If a symbol, it might be auto-prefixed if
declared `er-local' in the current file."
  (let ((name (er-read-symbol-name in)))
    (cond
     ((er-number? name)
      (funcall er-*orig-read* name))
     ((zerop (length name))
      '##)
     (t
      (intern (er-maybe-prefixed name))))))

(defvar er-*prefixed-symbols* (make-hash-table :test #'equal))

(defun er-maybe-prefixed (name &optional filename)
  "Add a prefix to NAME if it is intended to be local to FILENAME."
  (unless filename (setq filename (er-get-filename)))
  (let* ((f (gethash filename er-*prefixed-symbols*))
         prefix)
    (cond
     ((not f)
      ;; nothing special with this file, return unchanged name
      name)
     ((and (setq prefix (gethash name f))
           (zerop (length prefix)))
      ;; if defined but empty prefix for this name, this is actually
      ;; an "exported" symbol -- leave as is.
      name)
     (prefix
      ;; if we have a prefix, join it with a dash
      (format "%s-%s" prefix name))
     ((intern-soft name)
      ;; no prefix found and the symbol is already interned, so leave
      ;; as is.
      name)
     ((setq prefix (gethash "" f))
      ;; "global" prefix registered for this file, and the symbol is
      ;; uninterned -- let's join them
      (format "%s-%s" prefix name))
     (t
      ;; when none of the above, leave the name as is
      name))))

(defun er-make-prefixed (name &optional prefix filename)
  "Register NAME as a symbol that should have the prefix PREFIX in FILENAME."
  (unless filename (setq filename (er-get-filename)))
  (unless prefix (setq prefix filename))
  (let ((f (gethash filename er-*prefixed-symbols*)))
    (unless f
      (setq f (make-hash-table :test #'equal))
      (puthash filename f er-*prefixed-symbols*))
    (puthash name prefix f)
    nil))

(defun er-read-list (in end &optional no-dot)
  "Read a list of elements from the input stream IN.
This reads until the END character has been observed.  If NO-DOT is nil then
it will support a dot character before the last element, producing an
\"improper\" list.  If NO-DOT is true, then if a single dot character is
encountered this will produce an error."
  (let ((ret nil) (p nil) ch)
    (catch 'exit
      (while t
        (er-skip-whitespace in)
        (setq ch (er-peek in))
        (cond
         ((not ch)
          (er-croak "Unterminated list"))
         ((eq ch end)
          (er-next in)
          (throw 'exit ret))
         ((eq ch ?\;)
          (er-skip-comment in))
         (t
          (let ((x (er-read-datum in)))
            (cond
             ((eq x '\.)
              (cond
               (no-dot (er-croak "Dot in wrong context"))
               (t
                (rplacd p (er-read-datum in))
                (er-skip-whitespace in)
                (setq ch (er-next in))
                (unless (eq ch end)
                  (er-croak "Dot in wrong context"))
                (throw 'exit ret))))
             (t
              (let ((cell (cons x nil)))
                (setq p (if ret
                            (rplacd p cell)
                          (setq ret cell)))))))))))))

(defun er-read-datum (in)
  "Read and return a Lisp datum from the stream IN."
  (er-skip-whitespace in)
  (let ((ch (er-peek in)) macrochar)
    (cond
     ((not ch)
      (er-croak "End of file during parsing"))
     ((eq ch ?\;)
      (er-skip-comment in)
      (er-read-datum in))
     ((eq ch ?\")
      (er-read-string))
     ((eq ch ?\?)
      (er-read-char))
     ((eq ch ?\()
      (er-next in)
      (er-read-list in ?\)))
     ((eq ch ?\[)
      (er-next in)
      (apply #'vector (er-read-list in ?\] t)))
     ((eq ch ?\')
      (er-next in)
      (list 'quote (er-read-datum in)))
     ((eq ch ?\`)
      (er-next in)
      (list '\` (er-read-datum in)))
     ((eq ch ?\,)
      (er-next in)
      (cond
       ((eq (er-peek in) ?\@)
        (er-next in)
        (list '\,@ (er-read-datum in)))
       (t
        (list '\, (er-read-datum in)))))
     ((setq macrochar (gethash ch er-*macro-chars*))
      (er-next in)
      (funcall macrochar in ch))
     (t
      (er-read-symbol in)))))

(defvar er-*substitutions*)

(defun er-read-internal (in)
  "Read a Lisp expression from the input stream IN."
  ;; HACK: calling the original reader with (funcall er-*orig-read*
  ;; in) will not work.  After digging the C code (lread.c) my
  ;; conclusion is that `read' does not support a (uncompiled) lambda
  ;; expression as input stream.  This contradicts the documentation
  ;; so I'd call it a bug in Emacs.  Any case, a fbound symbol works
  ;; so we use %er-reader-insym for that.
  ;;
  ;; Update: it is a bug and it was confirmed [1] and fixed [2] within
  ;; hours!  Emacs is ALIVE!
  ;;
  ;; [1] https://debbugs.gnu.org/cgi/bugreport.cgi?bug=22961
  ;; [2] http://git.savannah.gnu.org/cgit/emacs.git/commit/?id=711ca36
  (fset '%er-reader-insym in)
  (unwind-protect
      (let ((er-*substitutions* (list)))
        (er-read-datum in))
    (fset '%er-reader-insym nil)))

(defun er-def-syntax (ch reader)
  "Assign a READER function to execute when the character CH is encountered."
  (puthash ch reader er-*macro-chars*))

(defun er-index (elt lst)
  "Return the index of ELT in LST.
Returns nil if ELT isn’t in LST."
  (let ((index 0))
    (catch 'exit
      (while lst
        (if (eq elt (car lst))
            (throw 'exit index)
          (setq index (1+ index))
          (setq lst (cdr lst)))))))

(defun er-substitute (orig cell)
  "Replace occurrences  of CELL in ORIG with ORIG."
  (cl-labels
      ((subst-in (thing)
         (cond
          ((eq thing cell)
           orig)
          ((consp thing)
           (subst-in-list thing)
           thing)
          ((stringp thing)
           thing)
          ((arrayp thing)
           (subst-in-array thing)
           thing)
          (t
           thing)))
       (subst-in-list (lst)
         (rplaca lst (subst-in (car lst)))
         (rplacd lst (subst-in (cdr lst))))
       (subst-in-array (array)
         (cl-loop for el across array
                  for i upfrom 0
                  do (aset array i (subst-in el)))))
    (subst-in orig)))

(defconst er-*all-digits* '( ?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9
                             ?a ?b ?c ?d ?e ?f ?g ?h ?i ?j
                             ?k ?l ?m ?n ?o ?p ?q ?r ?s ?t
                             ?u ?v ?w ?x ?y ?z))

(er-def-syntax ?#
               (lambda (in ch)
                 (let ((x (funcall in)))
                   (cond
                    ((er-digit? x)
                     (funcall in x)
                     (let ((num (er-read-integer in)))
                       (setq x (er-peek in))
                       (cond
                        ((and read-circle (eq x ?=))
                         ;; #1=...
                         (er-next in)
                         (let* ((placeholder (cons nil nil))
                                (cell (cons num placeholder)))
                           (setq er-*substitutions*
                                 (cons cell er-*substitutions*))
                           (let ((tok (er-read-datum in)))
                             (er-substitute tok placeholder)
                             (rplacd cell tok))))

                        ((and read-circle (eq x ?#))
                         ;; #1#
                         (er-next in)
                         (let ((x (assq num er-*substitutions*)))
                           (if (consp x)
                               (cdr x)
                             (er-croak "Cannot find substitution for #%d#"
                                       num))))

                        ((and (<= num 36)
                              (or (eq x ?r) (eq x ?R)))
                         ;; #16rFF
                         (er-next in)
                         (let* ((base num)
                                (digits (cl-subseq er-*all-digits* 0 base))
                                (num 0)
                                (negative? (cond ((eq ?- (er-peek in))
                                                  (er-next in)
                                                  t)
                                                 ((eq ?+ (er-peek in))
                                                  (er-next in)
                                                  nil))))
                           (er-read-while in
                                          (lambda (ch)
                                            (let ((v (er-index (downcase ch)
                                                               digits)))
                                              (when v
                                                (setq num
                                                      (+ v (* num base)))))))
                           (if negative? (- num) num)))

                        (t (er-croak "Unsupported #%d%c syntax" num x)))))

                    ((memq x '( ?s ?^ ?& ?\[ ?\( ?@ ?! ?$ ?: ?#
                                ?x ?X ?o ?O ?b ?B))
                     ;; let the original reader to deal with these.
                     (funcall in x)
                     (funcall in ch)
                     (er-orig-read))

                    ((eq x ?\')
                     (list 'function (er-read-datum in)))

                    ((eq x ?\/)
                     (er-read-regexp in))

                    (t
                     (er-croak "Unsupported #%c syntax" x))))))

(defun er-read-regexp (in)
  "Read a regular expression from the input stream IN."
  (let ((ret (list)))
    (catch 'exit
      (while t
        (let ((ch (funcall in)))
          (cond
           ((eq ch ?\\)
            (let ((next (funcall in)))
              (cond
               ((memq next '(?\\ ?/ ?\) ?\( ?\| ?\{ ?\}))
                (push next ret))
               ((eq next ?n)
                (push ?\n ret))
               ((eq next ?f)
                (push ?\f ret))
               ((eq next ?r)
                (push ?\r ret))
               ((eq next ?t)
                (push ?\t ret))
               (t
                (when (memq next '(?\* ?\+ ?\. ?\? ?\[ ?\] ?\^ ?\$ ?\\))
                  (push ?\\ ret))
                (funcall in next)))))
           ((memq ch '(?\) ?\( ?\| ?\{ ?\}))
            (push ?\\ ret)
            (push ch ret))
           ((eq ch ?/)
            (throw 'exit nil))
           ((not ch)
            (er-croak "Unterminated regexp"))
           (t
            (push ch ret))))))
    (apply #'string (nreverse ret))))

(defun er-read (&optional in)
  "Read a Lisp expression from the input stream IN."
  (if (and load-file-name
           (string-match "\\.elc$" load-file-name))
      (funcall er-*orig-read* in)
    (let ((er-*read-filename* (er-get-filename)))
      (er-read-internal (er-make-stream in)))))

(defun er-read-from-string (str &optional start end)
  "Read a Lisp expression from the string STR.
Reading starts from position START and stops at END."
  (let ((er-*read-filename* (er-get-filename)))
    (let* ((stream (er-make-stream
                    (substring-no-properties str start end)))
           (token (er-read-internal stream)))
      (cons token (+ (or start 0)
                     (funcall stream :pos))))))

(defun er-get-filename ()
  "Return the filename referring to the current context."
  (or er-*read-filename*
      load-file-name
      (and (boundp 'byte-compile-current-file) byte-compile-current-file)
      (and (boundp 'byte-compile-dest-file) byte-compile-dest-file)
      (buffer-file-name (current-buffer))
      (buffer-name (current-buffer))))

(defmacro er-local (prefix &optional names)
  "Declare that the given NAMES (list of strings) should be auto-prefixed.
The given PREFIX can be a symbol, string or nil.
This makes it possible to write:

    (er-local \"my-library-name\" (\"foo\" \"bar\"))
    (defun foo (...) ...)
    (defun bar (...) ...)

    ;; you can refer to foo and bar freely in the current file
    ;; but from other files, the symbols will be accessed
    ;; as my-library-name-foo and my-library-name-bar

If the prefix is nil, it will default to the current file/buffer
name and those symbols will be rather inaccessible from other
files (or it'll be really hard to type them manually).  Note that
without a prefix, the full file name is recorded in the elc file
during byte compilation."
  (unless names (setq names '("")))
  `(eval-when-compile
     ,@(mapcar (lambda (name)
                 `(er-make-prefixed ,name ,prefix))
               names)))

;; install in a prog, so they're read all at once with the original
;; reader
(progn
  (fset 'read (symbol-function 'er-read))
  (fset 'read-from-string (symbol-function 'er-read-from-string))
  (setq load-read-function (symbol-function 'er-read)))

(provide 'elisp-reader)
;;; elisp-reader.el ends here
