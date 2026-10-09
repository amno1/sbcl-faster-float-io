;;;; Checks FLONUM-TO-STRING (the core of ~F, ~E, ~G and ~$) against the
;;;; original version, read from a copy of print.lisp (by default the
;;;; one from SBCL before any zmij work: commit c7621755f, read with git from the
;;;; source tree of the SBCL running the test, or ORIGINAL_REV). All five
;;;; return values must be equal, for many combinations of width, digits,
;;;; scale, fmin and exponent.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/flonum-to-string.lisp [count]

(in-package "SB-IMPL")

(defparameter *original-source*
  (let ((path "/tmp/original-print.lisp"))
    (sb-ext:run-program "/bin/sh"
                        (list "-c" (format nil "git -C ~A show ~A:src/code/print.lisp > ~A"
                                           (namestring (merge-pathnames "../../" (make-pathname :name nil :type nil :defaults sb-ext:*runtime-pathname*)))
                                           (or (sb-ext:posix-getenv "ORIGINAL_REV") "c7621755f")
                                           path)))
    path))

(let* ((text (with-open-file (s *original-source*)
               (let ((string (make-string (file-length s))))
                 (subseq string 0 (read-sequence string s)))))
       (start (search "(defun flonum-to-string" text))
       (form (let ((*package* (find-package "SB-IMPL")))
               (read-from-string text t nil :start start))))
  (eval `(defun reference-flonum-to-string ,@(cddr form))))

(defvar *failures* 0)
(defvar *checked* 0)

(defun test (x &rest args)
  (incf *checked*)
  (let ((new (multiple-value-list (apply #'flonum-to-string x args)))
        (old (multiple-value-list (apply #'reference-flonum-to-string x args))))
    (unless (equal new old)
      (when (< (incf *failures*) 30)
        (format t "FAIL ~S ~S: new ~S, original ~S~%" x args new old)))))

(defparameter *widths* '(nil 1 2 3 5 8 12 30))
(defparameter *fdigits* '(nil 0 1 2 3 6 17 40))
(defparameter *scales* '(nil 0 1 2 -1 -3))
(defparameter *fmins* '(nil 0 1 3))
(defparameter *exponents* '(nil 1 -2 5))

(defun test-all-args (x)
  (dolist (width *widths*)
    (dolist (fdigits *fdigits*)
      (dolist (scale *scales*)
        (dolist (fmin *fmins*)
          (dolist (exponent *exponents*)
            ;; ~E (EXPONENT given) and ~F (no exponent) are the real uses.
            (when (or (null exponent) fdigits)
              (test x width fdigits scale fmin exponent))))))))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 3000))
      (state (sb-ext:seed-random-state 17)))
  (dolist (x (list 0d0 0.0 1d0 1.0 0.5d0 0.125d0 2.5d0 9.995d0 0.001 0.015d0
                   123.456d0 1d7 12345678.9d0 1d22 1d300 1.7976931348623157d308
                   least-positive-double-float 1d-300 3.4e38 1.5e-45 0.1d0))
    (test-all-args x))
  (dotimes (i count)
    (test-all-args (expt 10d0 (- (random 30d0 state) 15)))
    (test-all-args (coerce (expt 10d0 (- (random 20d0 state) 10)) 'single-float)))
  (format t "~:D calls checked~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
