;;;; Where does printing an integer spend its time?
;;;;
;;;; Part 1 times the ways of printing an integer of 18 digits and of 1-5
;;;; digits: PRIN1-TO-STRING, PRIN1 to a broadcast stream that discards the
;;;; output, (FORMAT NIL "~D"), and %OUTPUT-INTEGER-IN-BASE (the digit loop
;;;; itself) to the discarding stream. Also bignums of 25 digits.
;;;;
;;;; Part 2 profiles PRIN1-TO-STRING of 18-digit integers with SB-SPROF (CPU
;;;; mode) and prints the flat report.
;;;;
;;;;   ~/repos/sbcl-upstream/run-sbcl.sh --script benchmarks/profile-printer.lisp

(require :sb-sprof)

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 7))

(defun ns-per-call (f v)
  (declare (function f) (simple-vector v))
  (loop repeat *runs*
        minimize (progn
                   (sb-ext:gc)
                   (let ((t0 (get-internal-real-time)))
                     (loop for x across v do (funcall f x))
                     (/ (* 1d9 (/ (- (get-internal-real-time) t0)
                                  internal-time-units-per-second))
                        (length v))))))

(defun integers (state count digits)
  (coerce (loop repeat count
                collect (+ (expt 10 (1- digits))
                           (random (- (expt 10 digits) (expt 10 (1- digits))) state)))
          'simple-vector))

(let* ((state (sb-ext:seed-random-state 19))
       (n 200000)
       (long (integers state n 18))
       (short (coerce (loop repeat n collect (random 100000 state)) 'simple-vector))
       (bignums (integers state n 25))
       (null (make-broadcast-stream)))
  (format t "~A ~A~%~%" (lisp-implementation-type) (lisp-implementation-version))
  (format t "Part 1: ns per call, best of ~D~%" *runs*)
  (flet ((row (name f v)
           (format t "  ~44A ~7,1F~%" name (ns-per-call f v))
           (finish-output)))
    (dolist (case (list (list "18 digits" long) (list "1-5 digits" short)
                        (list "25 digits (bignum)" bignums)))
      (destructuring-bind (label v) case
        (row (format nil "prin1-to-string, ~A" label) #'prin1-to-string v)
        (row (format nil "prin1 to a null stream, ~A" label)
             (lambda (x) (prin1 x null)) v)
        (row (format nil "(format nil \"~~D\"), ~A" label)
             (lambda (x) (format nil "~D" x)) v)
        (row (format nil "%output-integer-in-base, ~A" label)
             (lambda (x) (sb-impl::%output-integer-in-base x 10 null)) v))))
  (format t "~%Part 2: SB-SPROF, PRIN1-TO-STRING of 18-digit integers~%~%")
  (finish-output)
  (sb-sprof:with-profiling (:max-samples 100000 :mode :cpu :sample-interval 0.0002
                            :report :flat)
    ;; Sum the lengths: PRIN1-TO-STRING has no side effects, so the compiler
    ;; would delete calls whose result is unused.
    (let ((total 0))
      (loop repeat 40 do (loop for x across long
                               do (incf total (length (prin1-to-string x)))))
      (format t "~D characters~%" total))))
