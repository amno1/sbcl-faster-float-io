;;;; Checks SB-IMPL::FLONUM-TO-BUFFER (the stack-buffer path of ~F) against
;;;; FLONUM-TO-STRING: whenever it returns a result, the characters and the
;;;; LENGTH, LPOINT, TPOINT and point position values must be equal.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/buffer.lisp [count]

(in-package "SB-IMPL")

(load (merge-pathnames "common.lisp" *load-truename*))

(defvar *failures* 0)
(defvar *checked* 0)
(defvar *used* 0)

(defun test (x fdigits scale fmin exponent)
  (incf *checked*)
  (let ((buffer (make-string 64 :element-type 'base-char :initial-element #\?)))
    (multiple-value-bind (len lpoint tpoint point)
        (flonum-to-buffer buffer x fdigits scale fmin exponent)
      (when len
        (incf *used*)
        (multiple-value-bind (string olen olpoint otpoint opoint)
            (flonum-to-string x nil fdigits scale fmin exponent)
          (unless (and (string= string buffer :end2 len)
                       (eql len olen)
                       (eq lpoint olpoint)
                       (eq tpoint otpoint)
                       (eql point opoint))
            (cl-user::fail (*failures*)
              "FAIL ~S ~S: buffer ~S ~S ~S ~S, string ~S ~S ~S ~S~%"
              x (list fdigits scale fmin exponent)
              (subseq buffer 0 len) len lpoint tpoint
              string olen olpoint otpoint)))))))

;;; The values tried for each argument after X: fdigits, scale, fmin,
;;; exponent.
(defparameter *parameter-values*
  '((0 1 2 3 6 10 17 30)
    (nil 0 1 2 -1 -3)
    (nil 0 1 3)
    (nil 1 -2 5)))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 20000))
      (state (sb-ext:seed-random-state 23)))
  (flet ((all (x)
           (cl-user::map-combinations (lambda (args) (apply #'test x args))
                                      *parameter-values*)))
    (dolist (x (list 1d0 1.0 0.5d0 0.125d0 2.5d0 9.995d0 9.996d0 0.001 0.015d0
                     123.456d0 1d7 12345678.9d0 1d22 1d300 1.7976931348623157d308
                     least-positive-double-float 1d-300 3.4e38 1.5e-45 0.1d0))
      (all x))
    (dotimes (i count)
      (all (expt 10d0 (- (random 30d0 state) 15)))
      (all (coerce (expt 10d0 (- (random 20d0 state) 10)) 'single-float))))
  (format t "~:D checked, ~:D through the buffer~%" *checked* *used*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
