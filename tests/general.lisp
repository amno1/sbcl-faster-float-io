;;;; Checks FORMAT-GENERAL-AUX (~G) against the original
;;;; version, read from a copy of target-format.lisp (by default the
;;;; one from SBCL before any zmij work: commit c7621755f, read with git from the
;;;; source tree of the SBCL running the test, or ORIGINAL_REV), for a grid of every ~G
;;;; parameter: w, d, e, k, overflow char, pad char, marker and @.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/general.lisp [count]

(in-package "SB-FORMAT")

(load (merge-pathnames "common.lisp" *load-truename*))

(let* ((text (cl-user::original-source "src/code/target-format.lisp"))
       (start (search "(defun format-general-aux" text))
       (form (let ((*package* (find-package "SB-FORMAT")))
               (read-from-string text t nil :start start))))
  (eval `(defun reference-format-general-aux ,@(cddr form))))

(defvar *failures* 0)
(defvar *checked* 0)

(defun run (fn x args)
  (handler-case (with-output-to-string (s) (apply fn s x args))
    (error (c) (list :error (type-of c)))))

;;; The values tried for each parameter of FORMAT-GENERAL-AUX, in its
;;; argument order: w, d, e, k (including NIL), overflow char, pad char,
;;; marker, @.
(defparameter *parameter-values*
  '((nil 1 6 10 15)
    (nil 0 1 3 8)
    (nil 1 2 3)
    (nil 1 0 2 -1 3)
    (nil #\*)
    (#\Space #\_)
    (nil #\x)
    (nil t)))

(defun test (x)
  (cl-user::map-combinations
   (lambda (args)
     (incf *checked*)
     (let ((new (run #'format-general-aux x args))
           (old (run #'reference-format-general-aux x args)))
       (unless (equal new old)
         (cl-user::fail (*failures*)
           "FAIL ~S ~S: new ~S, original ~S~%" x args new old))))
   *parameter-values*))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 150))
      (state (sb-ext:seed-random-state 29)))
  (dolist (x (list 1d0 -1d0 1.0 0.5d0 0.125d0 9.995d0 9.9999d0 0.001 123.456d0
                   -123.456 1d7 1d22 1d100 1d300 1.7976931348623157d308 1d-300
                   least-positive-double-float 3.4e38 1.5e-45 0.1d0 0d0 -0.0
                   sb-ext:double-float-positive-infinity))
    (test x))
  ;; Direct check of the helper ~G uses without D: its exponent and length
  ;; must equal FLONUM-EXPONENT's and FLONUM-TO-STRING's.
  (let ((state (sb-ext:seed-random-state 31)))
    (flet ((check (x)
             (unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x) (zerop x))
               (let ((x (abs x)))
                 (incf *checked*)
                 (multiple-value-bind (k len) (sb-impl::flonum-exponent-and-length x)
                   (let ((k0 (sb-impl::flonum-exponent x))
                         (len0 (nth-value 1 (sb-impl::flonum-to-string x))))
                     (unless (and (eql k k0) (eql len len0))
                       (cl-user::fail (*failures*)
                         "FAIL helper ~S: ~S ~S, expected ~S ~S~%"
                         x k len k0 len0))))))))
      (dotimes (i 300000)
        (check (sb-kernel:make-double-float (random (ash 1 31) state)
                                            (random (ash 1 32) state)))
        (check (sb-kernel:make-single-float (random (ash 1 31) state)))
        (check (expt 10d0 (- (random 40d0 state) 20))))
      (dolist (x (list 1d0 10d0 0.1d0 1d7 1d8 123.456d0 1d-5 5d-324
                       least-positive-single-float most-positive-double-float))
        (check x))))
  (dotimes (i count)
    (test (* (if (zerop (random 2 state)) 1 -1)
             (expt 10d0 (- (random 600d0 state) 300))))
    (test (coerce (expt 10d0 (- (random 70d0 state) 35)) 'single-float)))
  (format t "~:D calls checked~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
