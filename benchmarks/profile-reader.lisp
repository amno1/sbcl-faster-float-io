;;;; Where does READ-FROM-STRING of an integer spend its time?
;;;;
;;;; Part 1 times READ-FROM-STRING on several kinds of token, to separate
;;;; the reader's fixed cost from the cost of building an integer:
;;;; integers of 1-5 and 18 digits, the same digits as a symbol (with a
;;;; letter in front, so no number is built), and PARSE-INTEGER of the
;;;; same digits without the reader.
;;;;
;;;; Part 2 profiles READ-FROM-STRING of 18-digit integers with SB-SPROF
;;;; (CPU mode) and prints the flat report.
;;;;
;;;;   ~/repos/sbcl-upstream/run-sbcl.sh --script benchmarks/profile-reader.lisp

(require :sb-sprof)

(defparameter *runs* 7)

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

(defun strings (state count limit &optional (prefix ""))
  (coerce (loop repeat count
                collect (format nil "~A~D" prefix (+ (floor limit 10)
                                                     (random (- limit (floor limit 10))
                                                             state))))
          'simple-vector))

(let* ((state (sb-ext:seed-random-state 11))
       (n 200000)
       (long (strings state n (expt 10 18)))
       (short (strings state n 100000))
       (long-symbols (strings state n (expt 10 18) "X"))
       (short-symbols (strings state n 100000 "X")))
  (format t "~A ~A~%~%" (lisp-implementation-type) (lisp-implementation-version))
  (format t "Part 1: ns per call, best of ~D~%" *runs*)
  (flet ((row (name f v)
           (format t "  ~44A ~7,1F~%" name (ns-per-call f v))
           (finish-output)))
    (row "read-from-string, integer, 18 digits" #'read-from-string long)
    (row "read-from-string, symbol X + 18 digits" #'read-from-string long-symbols)
    (row "parse-integer, 18 digits" #'parse-integer long)
    (row "read-from-string, integer, 1-5 digits" #'read-from-string short)
    (row "read-from-string, symbol X + 1-5 digits" #'read-from-string short-symbols)
    (row "parse-integer, 1-5 digits" #'parse-integer short))
  (format t "~%Part 2: SB-SPROF, READ-FROM-STRING of 18-digit integers~%~%")
  (finish-output)
  (sb-sprof:with-profiling (:max-samples 100000 :mode :cpu :sample-interval 0.0002
                            :report :flat)
    (loop repeat 40 do (loop for s across long do (read-from-string s)))))
