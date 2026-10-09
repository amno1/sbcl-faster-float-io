;;;; Checks the Eisel-Lemire fast path of the float reader (MAKE-FLOAT/FAST in
;;;; src/code/reader.lisp, branch sbcl-parse-float): every string is read
;;;; with the fast path, and again with it switched off (MAKE-FLOAT/FAST
;;;; replaced by (CONSTANTLY NIL), so the original exact rational code runs).
;;;; The results must be identical: the same float, bit for bit (so -0.0 and
;;;; 0.0 differ), or the same kind of error.
;;;;
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script tests/parse-float.lisp [count]

(in-package "SB-IMPL")

(defvar *failures* 0)
(defvar *checked* 0)
(defvar *fast* 0)

(defun read-outcome (string)
  (handler-case (let ((x (read-from-string string)))
                  (if (floatp x)
                      (list (type-of x)
                            (etypecase x
                              (single-float (sb-kernel:single-float-bits x))
                              (double-float (list (sb-kernel:double-float-high-bits x)
                                                  (sb-kernel:double-float-low-bits x)))))
                      (list :not-a-float x)))
    (error (c) (list :error (type-of c)))))

(defparameter *fast-function* (fdefinition 'make-float/fast))

(defun test (string)
  (incf *checked*)
  (let* ((fast (progn
                 (sb-ext:without-package-locks
                   (setf (fdefinition 'make-float/fast)
                         (lambda (buf)
                           (let ((x (funcall *fast-function* buf)))
                             (when x (incf *fast*))
                             x))))
                 (read-outcome string)))
         (exact (progn
                  (sb-ext:without-package-locks
                    (setf (fdefinition 'make-float/fast) (constantly nil)))
                  (read-outcome string))))
    (unless (equal fast exact)
      (when (< (incf *failures*) 30)
        (format t "FAIL ~S (~A): fast ~S, exact ~S~%"
                string *read-default-float-format* fast exact)))))

(defun random-digits (n state)
  (let ((s (make-string n)))
    (dotimes (i n s)
      (setf (char s i) (digit-char (random 10 state))))))

(defun random-decimal (state)
  ;; Sign, digits with a point somewhere, maybe an exponent with a marker.
  (let* ((n (1+ (random (if (zerop (random 4 state)) 25 19) state)))
         (digits (random-digits n state))
         (point (random (1+ n) state))
         (zeros (make-string (random 4 state) :initial-element #\0))
         (mantissa (concatenate 'string
                                (case (random 3 state) (0 "-") (1 "+") (t ""))
                                zeros (subseq digits 0 point) "." (subseq digits point)))
         (marker (char "eEdDfFsSlL" (random 10 state))))
    (if (and (< point n) (zerop (random 3 state)))
        mantissa                        ; a point and digits after it: a float
        (format nil "~A~C~D" mantissa marker (- (random 801 state) 400)))))

(defun with-both-defaults (thunk)
  (dolist (*read-default-float-format* '(single-float double-float))
    (funcall thunk)))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 200000))
      (state (sb-ext:seed-random-state 41)))
  (unwind-protect
       (progn
         ;; Boundaries, halfway cases and odd syntax.
         (with-both-defaults
           (lambda ()
             (dolist (s '("0.0" "-0.0" "+0.0" "0.0d0" "-0.0d0" "0e0" "-0e5" "0.000e-999"
                          ".5" "5." "-.5" "1e5" "1d5" "1f5" "1s5" "1l5" "1E5" "1r5"
                          "1.7976931348623157d308" "1.7976931348623158d308"
                          "1.7976931348623159d308" "1.8d308" "1d309"
                          "4.9406564584124654d-324" "5d-324" "2.4703282292062327d-324"
                          "2.4703282292062328d-324" "3d-324" "1d-324" "1d-400"
                          "2.2250738585072011d-308" "2.2250738585072012d-308"
                          "2.2250738585072014d-308" "2.225073858507201d-308"
                          "3.4028235e38" "3.4028236e38" "3.5e38" "1.4e-45" "7e-46" "1e-46"
                          "1.17549435e-38" "1.1754942e-38"
                          "9007199254740993" "9007199254740993.0" "9007199254740993d0"
                          "9007199254740992.5d0" "9007199254740995d0" "16777217.0" "16777217f0"
                          "16777219f0" "0.1" "0.2" "0.3" "1.1" "123.456" "1d23" "8.5d-1"
                          "1234567890123456789.0" "12345678901234567890.0" "1.234567890123456789d0"
                          "0.00000000000000000001234567890123456789" "1e100000" "1e-100000"
                          "1e99999999999999999999" "00000000000000000000001.5"))
               (test s)
               (test (string-downcase s)))))
         ;; Exact halfway cases: (2k+1) * 2^(e-1) for doubles near 2^53, scaled
         ;; by powers of ten that keep them within 19 digits.
         (with-both-defaults
           (lambda ()
             (loop for k from 0 below 2000
                   for m = (+ (expt 2 53) 1 (* 2 k))
                   do (test (format nil "~D.0" m))
                      (test (format nil "~Dd0" m))
                      (test (format nil "~D0d-1" m))
                      (test (format nil "~D.5d0" (floor m 2))))
             (loop for k from 0 below 2000
                   for m = (+ (expt 2 24) 1 (* 2 k))
                   do (test (format nil "~D.0" m))
                      (test (format nil "~Df0" m)))))
         ;; Printed floats, which must also read back to themselves.
         (dotimes (i count)
           (let ((d (sb-kernel:make-double-float (- (random (ash 1 31) state))
                                                 (random (ash 1 32) state)))
                 (f (sb-kernel:make-single-float (- (random (ash 1 31) state)))))
             (dolist (x (list d f (abs d) (abs f)))
               (unless (or (sb-ext:float-nan-p x) (sb-ext:float-infinity-p x))
                 (with-both-defaults
                   (lambda () (test (prin1-to-string x))))))))
         ;; Random decimal strings.
         (dotimes (i count)
           (let ((s (random-decimal state)))
             (with-both-defaults (lambda () (test s))))))
    (setf (fdefinition 'make-float/fast) *fast-function*))
  (format t "~:D strings read, ~:D through the fast path~%" *checked* *fast*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
