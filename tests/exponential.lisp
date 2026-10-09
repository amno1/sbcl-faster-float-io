;;;; Checks FORMAT-EXP-AUX (~E, also used by ~G) against the original
;;;; version, read from a copy of target-format.lisp (by default the
;;;; one from SBCL before any zmij work: commit c7621755f, read with git from the
;;;; source tree of the SBCL running the test, or ORIGINAL_REV), for a grid of every ~E
;;;; parameter: w, d, e, k, overflow char, pad char, marker and @.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/exponential.lisp [count]

(in-package "SB-FORMAT")

(defparameter *original-source*
  (let ((path "/tmp/original-target-format.lisp"))
    (sb-ext:run-program
     "/bin/sh"
     (list "-c" (format nil "git -C ~A show ~A:src/code/target-format.lisp > ~A"
                        (namestring (merge-pathnames "../../" (make-pathname :name nil :type nil :defaults sb-ext:*runtime-pathname*)))
                        (or (sb-ext:posix-getenv "ORIGINAL_REV") "c7621755f")
                        path)))
    path))

(let* ((text (with-open-file (s *original-source*)
               (let ((string (make-string (file-length s))))
                 (subseq string 0 (read-sequence string s)))))
       (start (search "(defun format-exp-aux" text))
       (form (let ((*package* (find-package "SB-FORMAT")))
               (read-from-string text t nil :start start))))
  (eval `(defun reference-format-exp-aux ,@(cddr form))))

(defvar *failures* 0)
(defvar *checked* 0)

(defun run (fn x args)
  (handler-case (with-output-to-string (s) (apply fn s x args))
    (error (c) (list :error (type-of c)))))

(defun test (x)
  (dolist (w '(nil 1 6 10 15))
    (dolist (d '(nil 0 1 3 8))
      (dolist (e '(nil 1 2 3))
        (dolist (k '(1 0 2 -1 3))
          (dolist (ovf '(nil #\*))
            (dolist (pad '(#\Space #\_))
              (dolist (marker '(nil #\x))
                (dolist (atsign '(nil t))
                  (let ((args (list w d e k ovf pad marker atsign)))
                    (incf *checked*)
                    (let ((new (run #'format-exp-aux x args))
                          (old (run #'reference-format-exp-aux x args)))
                      (unless (equal new old)
                        (when (< (incf *failures*) 30)
                          (format t "FAIL ~S ~S: new ~S, original ~S~%"
                                  x args new old))))))))))))))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 150))
      (state (sb-ext:seed-random-state 29)))
  (dolist (x (list 1d0 -1d0 1.0 0.5d0 0.125d0 9.995d0 9.9999d0 0.001 123.456d0
                   -123.456 1d7 1d22 1d100 1d300 1.7976931348623157d308 1d-300
                   least-positive-double-float 3.4e38 1.5e-45 0.1d0 0d0 -0.0
                   sb-ext:double-float-positive-infinity))
    (test x))
  (dotimes (i count)
    (test (* (if (zerop (random 2 state)) 1 -1)
             (expt 10d0 (- (random 600d0 state) 300))))
    (test (coerce (expt 10d0 (- (random 70d0 state) 35)) 'single-float)))
  (format t "~:D calls checked~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
