;;;; ns per call for the float FORMAT directives and PRIN1-TO-STRING, best
;;;; of RUNS (default 7) passes over 200k doubles, in two ranges of
;;;; magnitude, spread evenly over the magnitudes within each:
;;;;
;;;;   0.1 to 10^7    prices, coordinates, measurements
;;;;   0.001 to 0.1   small values, e.g. neural-network weights; ~,2F of
;;;;                  values below 0.01 takes another path
;;;;
;;;; Works on any SBCL, so stock and zmij builds can be compared:
;;;;
;;;;   ~/repos/sbcl-upstream/run-sbcl.sh --script benchmarks/format-bench.lisp
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script benchmarks/format-bench.lisp

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 7))

(defun ns-per-call (f v)
  (declare (function f)
           (simple-vector v))
  (funcall f (aref v 0))
  (loop repeat *runs*
        minimize
        (progn
          (sb-ext:gc)
          (let ((t0 (get-internal-real-time)))
            (loop for x across v do (funcall f x))
            (/ (* 1d9 (/ (- (get-internal-real-time) t0)
                         internal-time-units-per-second))
               (length v))))))

;;; COUNT doubles from 10^LOW to 10^HIGH, spread evenly over the magnitudes.
(defun make-values (seed low high &optional (count 200000))
  (let ((state (sb-ext:seed-random-state seed)))
    (coerce (loop repeat count
                  collect (expt 10d0 (+ low (random (float (- high low) 1d0) state))))
            'simple-vector)))

(let ((moderate (make-values 3 -1 7))
      (small (make-values 4 -3 -1))
      (null (make-broadcast-stream)))
  (format t "~A ~A, best of ~D~%" (lisp-implementation-type)
          (lisp-implementation-version) *runs*)
  (format t "~28A ~14@A ~14@A~%" "ns per call" "0.1 to 10^7" "0.001 to 0.1")
  (flet ((bench (name f)
           (format t "~28A ~14,1F ~14,1F~%" name
                   (ns-per-call f moderate) (ns-per-call f small))
           (finish-output)))
    (bench "prin1-to-string" (lambda (x) (prin1-to-string x)))
    (bench "~A"   (lambda (x) (format nil "~A" x)))
    (bench "~,2F" (lambda (x) (format nil "~,2F" x)))
    (bench "~F"   (lambda (x) (format nil "~F" x)))
    (bench "~10,2F" (lambda (x) (format nil "~10,2F" x)))
    (bench "~12F (width only)" (lambda (x) (format nil "~12F" x)))
    (bench "~,3E" (lambda (x) (format nil "~,3E" x)))
    (bench "~E"   (lambda (x) (format nil "~E" x)))
    (bench "~G"   (lambda (x) (format nil "~G" x)))
    (bench "~,2G" (lambda (x) (format nil "~,2G" x)))
    (bench "~$"   (lambda (x) (format nil "~$" x)))
    (bench "x=~,2F y=~,2F" (lambda (x) (format nil "x=~,2F y=~,2F" x x)))
    (bench "~,2F to a null stream" (lambda (x) (format null "~,2F" x)))))
