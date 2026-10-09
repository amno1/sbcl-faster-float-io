;;;; Checks the FORMAT transform for control strings that are one ~F, ~E,
;;;; ~G or ~$ directive: compiled (FORMAT NIL "<directive>" X) must return
;;;; the same string as
;;;; FORMAT interpreting the same control string, for floats (including
;;;; infinities and NaN), rationals, integers, complexes and non-numbers.
;;;; Also checks that the transform fires when it should (the compiled code
;;;; calls FORMAT-FIXED-STRING, FORMAT-EXPONENTIAL-STRING, ...) and not when
;;;; it should not.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/transform.lisp

(in-package "SB-FORMAT")

(load (merge-pathnames "common.lisp" *load-truename*))

(defvar *failures* 0)
(defvar *checked* 0)

(defun calls-p (fn name)
  (search name (with-output-to-string (s) (disassemble fn :stream s))))

(defun compiled (control)
  (compile nil `(lambda (x) (format nil ,control x))))

(defun outcome (thunk)
  (handler-case (funcall thunk)
    (error (c) (list :error (type-of c)))))

(defparameter *controls*
  '(;; ~F
    "~F" "~,2F" "~,0F" "~8,3F" "~,1F" "~12,6F" "~3,1F" "~,2,1F" "~,3,-2F"
    "~,20F" "~12F" "~5F" "~2F" "~12,,2F" "~@F" "~10@F" "~,2@F" "~6,,,'*F"
    "~4,2,,'*F" "~10,2,,,'_F" "~1,,,'xF" "~f" "~,2f" "~0,0F" "~1,0F"
    ;; ~E
    "~E" "~,3E" "~10,2E" "~,2,2E" "~,4,,2E" "~,3,,-1E" "~,3,,2E" "~@E"
    "~8,2,1,,'*E" "~12,3,2,1,'*,'_,'dE" "~,,,0E" "~e" "~3E" "~,0E"
    ;; ~G
    "~G" "~,2G" "~12,3G" "~,3,2G" "~8,2,,,'*G" "~@G" "~15,4,,1G" "~g"
    "~3G" "~,0G" "~10,,,,'*G"
    ;; ~$
    "~$" "~10,4$" "~,3$" "~@$" "~:$" "~:@$" "~8,2,3$" "~,2,4,'*$" "~0$"
    "~1,1,1$"))

(defun expected-function (control)
  (ecase (char-upcase (char control (1- (length control))))
    (#\F "FORMAT-FIXED-STRING")
    (#\E "FORMAT-EXPONENTIAL-STRING")
    (#\G "FORMAT-GENERAL-STRING")
    (#\$ "FORMAT-DOLLARS-STRING")))

(defparameter *values*
  (list 1d0 -1d0 1.0 -0.0 0d0 0.5d0 0.125d0 2.5d0 9.995d0 0.001d0 0.006d0
        123.456d0 -123.456 1d7 12345678.9d0 1d22 1d300 1d-300 0.1d0
        least-positive-double-float most-positive-single-float
        sb-ext:double-float-positive-infinity sb-ext:single-float-negative-infinity
        (sb-kernel:make-double-float #x7FF80000 0) ; a quiet NaN
        1/3 -22/7 (expt 2 100) 0 42 -7 #c(1.5 2d0) 'foo "bar" #\x nil))

(sb-int:with-float-traps-masked (:invalid :overflow :divide-by-zero)
  (dolist (control *controls*)
    (let ((fn (compiled control)))
      (incf *checked*)
      (unless (calls-p fn (expected-function control))
        (cl-user::fail (*failures*) "FAIL ~S: transform did not fire~%" control))
      (dolist (x *values*)
        (incf *checked*)
        (let ((new (outcome (lambda () (funcall fn x))))
              (old (outcome (lambda () (format nil (copy-seq control) x)))))
          (unless (equal new old)
            (cl-user::fail (*failures*)
              "FAIL ~S ~S: compiled ~S, interpreted ~S~%" control x new old)))))))

;;; Control strings the transform must leave alone.
(dolist (control '("~VF" "~,VF" "~#F" "x=~,2F" "~,2F~%" "~:F" "~A" "~VE" "~:E"
                   "~:G" "~,V$" "~#$" "x~$" "~1,2,3,4,5,6F" "~D"))
  (incf *checked*)
  (when (ignore-errors
         (let ((fn (compiled control)))
           (some (lambda (name) (calls-p fn name))
                 '("FORMAT-FIXED-STRING" "FORMAT-EXPONENTIAL-STRING"
                   "FORMAT-GENERAL-STRING" "FORMAT-DOLLARS-STRING"))))
    (cl-user::fail (*failures*) "FAIL ~S: transform fired but should not~%" control)))

(format t "~:D checks~%" *checked*)
(format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
(sb-ext:exit :code (if (plusp *failures*) 1 0))
