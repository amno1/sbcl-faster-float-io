;;;; Benchmark of SBCL's shortest float printer, and of fixed-position
;;;; digits (FLONUM-TO-DIGITS with a position, behind ~F ~E ~G ~$) at
;;;; position -2, i.e. two digits after the point, on values from 0.1 to
;;;; 10^7 as in format-bench.lisp.
;;;;
;;;; Run with any SBCL (stock or zmij build) to compare:
;;;;   sbcl --script benchmarks/benchmark.lisp [count]
;;;;   ../sbcl/run-sbcl.sh --script benchmarks/benchmark.lisp [count]

(in-package "CL-USER")

(defun make-inputs (type count)
  (let ((state (sb-ext:seed-random-state 42))
        (v (make-array count)))
    (dotimes (i count v)
      (setf (aref v i)
            (loop for x = (ecase type
                            (double-float
                             (sb-kernel:make-double-float
                              (- (random (ash 1 32) state) (ash 1 31))
                              (random (ash 1 32) state)))
                            (single-float
                             (sb-kernel:make-single-float
                              (- (random (ash 1 32) state) (ash 1 31)))))
                  unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x)
                             (zerop x))
                    return x)))))

;;; COUNT values from 0.1 to 10^7, spread evenly over the magnitudes.
(defun make-ordinary-inputs (type count)
  (let ((state (sb-ext:seed-random-state 3)))
    (coerce (loop repeat count
                  collect (coerce (expt 10d0 (- (random 8d0 state) 1)) type))
            'simple-vector)))

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 7))

;;; Best of *RUNS* passes over INPUTS, in nanoseconds per call. The
;;; minimum is the least noisy estimate on a shared machine.
(defun ns-per-call (fn inputs)
  (declare (function fn) (simple-vector inputs))
  (funcall fn (aref inputs 0))          ; warm up
  (loop repeat *runs*
        minimize (progn
                   (sb-ext:gc :full t)
                   (let ((start (get-internal-real-time)))
                     (loop for x across inputs do (funcall fn x))
                     (/ (* 1d9 (/ (- (get-internal-real-time) start)
                                  internal-time-units-per-second))
                        (length inputs))))))

(let* ((count (if (second sb-ext:*posix-argv*)
                  (parse-integer (second sb-ext:*posix-argv*))
                  1000000))
       (sink (make-broadcast-stream))
       ;; ZMIJ-DECIMAL in current builds, ZMIJ-SHORTEST in early ones.
       (core (find-if (lambda (s) (and s (fboundp s)))
                      (list (find-symbol "ZMIJ-DECIMAL" "SB-IMPL")
                            (find-symbol "ZMIJ-SHORTEST" "SB-IMPL"))))
       (tests (list* (cons "flonum-to-digits"
                          (lambda (x) (sb-impl::flonum-to-digits (abs x))))
                    (cons "prin1-to-string" #'prin1-to-string)
                    (cons "prin1 to null stream"
                          (lambda (x) (prin1 x sink)))
                    ;; zmij builds only: digit generation without output.
                    (when core
                      (list (cons "zmij core"
                                  (let ((f (fdefinition core)))
                                    (lambda (x) (funcall f (abs x))))))))))
  (format t "~A ~A, ~:D inputs per type, best of ~D runs~%"
          (lisp-implementation-type) (lisp-implementation-version) count *runs*)
  (format t "zmij present: ~:[no~;yes~]~%~%"
          core)
  (format t "~24A ~14@A ~14@A~%" "operation" "single ns/op" "double ns/op")
  (let ((singles (make-inputs 'single-float count))
        (doubles (make-inputs 'double-float count)))
    (dolist (test tests)
      (format t "~24A ~14,1F ~14,1F~%" (car test)
              (ns-per-call (cdr test) singles)
              (ns-per-call (cdr test) doubles))))
  (format t "~%~24A ~14@A ~14@A~%" "0.1 to 10^7" "single ns/op" "double ns/op")
  (format t "~24A ~14,1F ~14,1F~%" "flonum-to-digits pos -2"
          (ns-per-call (lambda (x) (sb-impl::flonum-to-digits x -2))
                       (make-ordinary-inputs 'single-float count))
          (ns-per-call (lambda (x) (sb-impl::flonum-to-digits x -2))
                       (make-ordinary-inputs 'double-float count))))
