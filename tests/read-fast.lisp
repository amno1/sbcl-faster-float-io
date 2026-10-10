;;;; Checks the READ-TOKEN fast path (SB-IMPL::READ-NUMBER/FAST, branch
;;;; sbcl-read-fast): every string is read with the fast path and again
;;;; with it switched off, and the results must be identical: the same
;;;; objects (EQL, so the same type and bits), the same position after
;;;; each read, or the same kind of error.
;;;;
;;;; Covers random integers and floats, edge cases, tokens the fast path
;;;; must leave alone (symbols, ratios, escapes, package prefixes, ...),
;;;; several objects in one string, READ-PRESERVING-WHITESPACE, both
;;;; default float formats, *READ-BASE* 16, *READ-SUPPRESS*, and a
;;;; readtable in which a digit is not a constituent.
;;;;
;;;;   ~/repos/sbcl-read-fast/run-sbcl.sh --script tests/read-fast.lisp [count]

(in-package "SB-IMPL")

(defvar *failures* 0)
(defvar *checked* 0)
(defvar *fast-function* #'read-number/fast)

(defun outcome (function)
  "The values of FUNCTION, or the type of the error it signals."
  (handler-case (multiple-value-list (funcall function))
    (error (c) (list :error (type-of c)))))

;;; Read every object in STRING with READER until EOF, collecting each
;;; object and the stream position after it.
(defun read-all (string reader)
  (with-input-from-string (s string)
    (loop for object = (funcall reader s nil s)
          until (eq object s)
          collect (list object (file-position s)))))

(defun samep (a b)
  (or (eql a b)
      (and (consp a) (consp b)
           (samep (car a) (car b)) (samep (cdr a) (cdr b)))
      (and (stringp a) (stringp b) (string= a b))
      (and (symbolp a) (symbolp b) (null (symbol-package a)) (null (symbol-package b))
           (string= a b))))

(defun check (string &optional (reader #'read))
  (incf *checked*)
  (let ((fast (outcome (lambda () (read-all string reader))))
        (slow (progn
                (sb-ext:without-package-locks
                  (setf (fdefinition 'read-number/fast) (constantly nil)))
                (unwind-protect (outcome (lambda () (read-all string reader)))
                  (sb-ext:without-package-locks
                    (setf (fdefinition 'read-number/fast) *fast-function*))))))
    (unless (samep fast slow)
      (when (<= (incf *failures*) 50)
        (format t "FAIL ~S (base ~D, ~A, ~A): fast ~S, normal ~S~%"
                string *read-base* *read-default-float-format*
                (if (eq reader #'read) "read" "preserving") fast slow)
        (finish-output)))))

(defun random-number-string (state)
  (let ((digits (lambda (n)
                  (with-output-to-string (s)
                    (dotimes (i n) (write-char (digit-char (random 10 state)) s))))))
    (flet ((pick (&rest choices) (nth (random (length choices) state) choices)))
      (concatenate 'string
                   (pick "" "-" "+")
                   (funcall digits (random 22 state))
                   (pick "" "." (concatenate 'string "." (funcall digits (random 22 state))))
                   (pick "" (format nil "~C~A~D"
                                    (char "eEsSfFdDlLrRx" (random 13 state))
                                    (pick "" "-" "+")
                                    (random 400 state)))))))

(defparameter *edge-cases*
  '("0" "-0" "+0" "00012" "1." "-1." "123456789012345678" "1234567890123456789"
    "999999999999999999" "-999999999999999999" "12345678901234567890123"
    "0.0" "-0.0" ".5" "-.5" "+.5" "1.5" "1.e5" "1e5" "1E5" "1d5" "1D5" "1f5"
    "1s5" "1l5" "1r5" "1.5e-3" "1.5e+3" "1e400" "1e-400" "1d309" "1d-330"
    "1.7976931348623157d308" "1.7976931348623159d308" "4.9406564584124654d-324"
    "3.4028235e38" "3.5e38" "1e" "1e+" "1.5e" "." "+" "-" "+." "-." ".e5" "1.5.5"
    "1..5" "1/2" "-3/4" "123abc" "abc" "1a" "a1" "12\\3" "1|2|3" "|12|" "cl:car"
    "12:34" "#x1F" "#b101" "#.(+ 1 2)" "1(2)" "(1 2.5 -3)" "1 2 3" "  42  "
    "1;comment" "1'x" "1\"x\"" "1`x" "1,x" "12#34" "0.10000000000000000000001"
    "1e100001" "123456789012345678901234567890.5" "1.5d0 2.5f0 3" ".5." "5.."
    "-.e1" "+5e+5" "+5e-5" "1.0e0" "1.0E0x"))

;;; Check each of STRINGS with READER, with the special variables in
;;; BINDINGS, a list of (variable value), bound to their values.
(defun check-strings (strings &key (reader #'read) bindings)
  (progv (mapcar #'first bindings) (mapcar #'second bindings)
    (dolist (string strings)
      (check string reader))))

(defun random-number-strings (state count)
  (loop repeat count collect (random-number-string state)))

;;; Strings of four numbers, separated by spaces and parentheses.
(defun several-numbers-strings (state count)
  (loop repeat count
        collect (format nil "~A ~A(~A)~A"
                        (random-number-string state) (random-number-string state)
                        (random-number-string state) (random-number-string state))))

(let* ((count (if (second sb-ext:*posix-argv*)
                  (parse-integer (second sb-ext:*posix-argv*))
                  200000))
       (state (sb-ext:seed-random-state 13))
       (no-five (let ((rt (copy-readtable)))
                  ;; #\5 becomes whitespace: "15" is then two tokens.
                  (set-syntax-from-char #\5 #\Space rt)
                  rt)))
  (dolist (format '(single-float double-float))
    (let ((*read-default-float-format* format))
      (check-strings (append *edge-cases* (random-number-strings state count)))
      (check-strings (append *edge-cases* (random-number-strings state count))
                     :reader #'read-preserving-whitespace)
      (check-strings *edge-cases* :bindings '((*read-base* 16)))
      (check-strings *edge-cases* :bindings '((*read-suppress* t)))
      (check-strings (append *edge-cases*
                             (random-number-strings state (floor count 10)))
                     :bindings `((*readtable* ,no-five)))
      (check-strings (several-numbers-strings state (floor count 10)))))
  (format t "~:D strings checked~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
