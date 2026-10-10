;;;; Checks that PRIN1, PRIN1-TO-STRING and PRINC-TO-STRING lay out
;;;; floats exactly like SBCL's original printer: decimal point position,
;;;; padding zeros and exponent marker, under every
;;;; *READ-DEFAULT-FLOAT-FORMAT* and with *PRINT-PRETTY* on and off. Also
;;;; checks that zero, infinities and pprint dispatch entries for floats
;;;; keep the general path.
;;;;
;;;; The reference below is SBCL's original PRINT-FLOAT logic (the
;;;; callback version in src/code/print.lisp), fed with the digits from
;;;; FLONUM-TO-DIGITS. Digit correctness itself is checked by
;;;; correctness.lisp.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/print-format.lisp [count]

(in-package "SB-IMPL")

(load (merge-pathnames "common.lisp" *load-truename*))

(defun reference-print-float (float stream)
  (multiple-value-bind (k digits) (flonum-to-digits (abs float))
    (let ((position 0)
          (dot-position 0)
          (e-min -3)
          (e-max 8))
      (cond ((not (< e-min k e-max))
             (setf dot-position 1))
            ((plusp k)
             (setf dot-position k))
            (t
             (setf dot-position -1)
             (write-char #\0 stream)
             (write-char #\. stream)
             (loop repeat (- k) do (write-char #\0 stream))))
      (loop for c across digits
            do (when (= position dot-position)
                 (write-char #\. stream))
               (write-char c stream)
               (incf position))
      (when (<= position dot-position)
        (loop repeat (- dot-position position)
              do (write-char #\0 stream))
        (write-char #\. stream)
        (write-char #\0 stream))
      (if (< e-min k e-max)
          (print-float-exponent float 0 stream)
          (print-float-exponent float (1- k) stream)))))

(defun reference-string (x)
  (with-output-to-string (s)
    (when (minusp (float-sign x))
      (write-char #\- s))
    (reference-print-float x s)))

(defvar *failures* 0)

;;; PRIN1-TO-STRING and PRINC-TO-STRING (the string fast path), and PRIN1
;;; to a stream (PRINT-FLOAT), with and without *PRINT-PRETTY*.
(defun test (x)
  (unless (or (sb-ext:float-infinity-p x)
              (sb-ext:float-nan-p x)
              (zerop x))
    (let ((old (reference-string x)))
      (dolist (*print-pretty* '(nil t))
        (dolist (new (list (prin1-to-string x)
                           (princ-to-string x)
                           (with-output-to-string (s) (prin1 x s))))
          (unless (string= new old)
            (cl-user::fail (*failures*) "FAIL ~A pretty ~A ~S: printed ~S, expected ~S~%"
                  *read-default-float-format* *print-pretty* x new old)))))))

;;; Cases that must keep the general path.
(defun test-special-cases ()
  (flet ((expect (string thunk)
           (let ((got (funcall thunk)))
             (unless (string= got string)
               (cl-user::fail (*failures*) "FAIL special: got ~S, expected ~S~%" got string)))))
    (let ((*read-default-float-format* 'single-float))
      (expect "0.0" (lambda () (prin1-to-string 0.0)))
      (expect "-0.0d0" (lambda () (prin1-to-string -0d0)))
      (let ((inf sb-ext:double-float-positive-infinity))
        (expect (with-output-to-string (s)
                  (prin1 inf s))
                (lambda () (prin1-to-string inf))))
      (expect "-1.5" (lambda () (princ-to-string -1.5)))
      ;; A pprint dispatch entry for floats must win when pretty printing.
      (let ((*print-pprint-dispatch* (copy-pprint-dispatch)))
        (set-pprint-dispatch 'float (lambda (s x) (format s "<~,2F>" x)))
        (let ((*print-pretty* t))
          (expect "<1.50>" (lambda () (prin1-to-string 1.5)))
          (expect "<2.00>" (lambda () (princ-to-string 2d0))))
        (let ((*print-pretty* nil))
          (expect "1.5" (lambda () (prin1-to-string 1.5))))))))

(defun random-double (state)
  (sb-kernel:make-double-float (- (random (ash 1 32) state) (ash 1 31))
                               (random (ash 1 32) state)))

(defun random-single (state)
  (sb-kernel:make-single-float (- (random (ash 1 32) state) (ash 1 31))))

;;; M * 10^P as a double, and as a single where singles reach that far:
;;; the values that do not overflow.
(defun boundary-floats (p m)
  (remove nil
          (list (ignore-errors (coerce (* m (expt 10 p)) 'double-float))
                (when (< -46 p 30)
                  (ignore-errors (coerce (* (min m 99999999) (expt 10 p))
                                         'single-float))))))

(defun test-both-signs (x)
  (test x)
  (test (- x)))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 200000)))
  (test-special-cases)
  (dolist (format '(single-float double-float short-float long-float))
    (let ((*read-default-float-format* format)
          (state (sb-ext:seed-random-state 11)))
      ;; Every layout boundary: k from -330 to 310 around the switch
      ;; points -3 and 8, with 1, 2 and many digits.
      (cl-user::do-combinations
          ((p (cl-user::range -330 308))
           (m '(1 12 123456789 1234567890123456 9999999999999999))
           (x (boundary-floats p m)))
        (test-both-signs x))
      (dolist (x (list least-positive-double-float most-positive-double-float
                       least-positive-single-float most-positive-single-float
                       1d0 1.0 0.1 0.1d0 1d7 1d8 1e7 1e8 0.001 0.0001 1d-3 1d-4
                       123456.7 1234567.0 12345678.0 100.0 1d16 1d17))
        (test-both-signs x))
      (dotimes (i count)
        (test (random-double state))
        (test (random-single state)))))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
