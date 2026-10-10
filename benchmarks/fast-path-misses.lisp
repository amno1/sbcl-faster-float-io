;;;; What the READ-TOKEN fast path costs when it gives up.
;;;;
;;;; For tokens the fast path does not handle (symbols that start with a
;;;; digit, ratios, integers too long for it, floats with too many digits),
;;;; READ-NUMBER/FAST scans part of the token, gives up, and READ-TOKEN then
;;;; reads the whole token as before: the fast path's work is wasted. This
;;;; measures that waste: the same strings are read with READ-FROM-STRING
;;;; with the fast path on and off (READ-NUMBER/FAST replaced by a function
;;;; that returns NIL), alternately in one process, best of RUNS (default 9)
;;;; passes over 100k strings. Two tokens it does handle are included for
;;;; comparison.
;;;;
;;;;   ~/repos/sbcl-read-fast/run-sbcl.sh --script benchmarks/fast-path-misses.lisp

(in-package "SB-IMPL")

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 9))

(defparameter *fast* #'read-number/fast)
(defparameter *off* (lambda (stream firstchar)
                      (declare (ignore stream firstchar))
                      nil))

(defun ns-per-call (v)
  (declare (simple-vector v))
  (loop repeat *runs*
        minimize (progn
                   (sb-ext:gc)
                   (let ((t0 (get-internal-real-time)))
                     (loop for s across v do (read-from-string s))
                     (/ (* 1d9 (/ (- (get-internal-real-time) t0)
                                  internal-time-units-per-second))
                        (length v))))))

;;; NS-PER-CALL with the fast path on and with it off, alternating three
;;; times so that both see the same conditions; the best of each.
(defun on-and-off (v)
  (let ((on most-positive-double-float)
        (off most-positive-double-float))
    (dotimes (i 3)
      (sb-ext:without-package-locks
        (setf (fdefinition 'read-number/fast) *fast*))
      (setq on (min on (ns-per-call v)))
      (sb-ext:without-package-locks
        (setf (fdefinition 'read-number/fast) *off*))
      (setq off (min off (ns-per-call v))))
    (sb-ext:without-package-locks
      (setf (fdefinition 'read-number/fast) *fast*))
    (values on off)))

(defun digits (state n)
  (with-output-to-string (s)
    (write-char (digit-char (1+ (random 9 state))) s)
    (dotimes (i (1- n)) (write-char (digit-char (random 10 state)) s))))

(let* ((state (sb-ext:seed-random-state 17))
       (n 100000)
       (cases
         `(("symbol, letter first (foo123)"
            ,(lambda () (format nil "FOO~D" (random 1000000 state))))
           ("symbol, 1 digit first (1abc)"
            ,(lambda () (format nil "~DABC" (random 10 state))))
           ("symbol, 18 digits first"
            ,(lambda () (format nil "~AX" (digits state 18))))
           ("ratio (123456/789)"
            ,(lambda () (format nil "~A/~A" (digits state 6) (digits state 3))))
           ("integer, 25 digits (bignum)"
            ,(lambda () (digits state 25)))
           ("float, 25 significant digits"
            ,(lambda () (format nil "~A.~A" (digits state 12) (digits state 13))))
           ("hit: integer, 18 digits"
            ,(lambda () (digits state 18)))
           ("hit: float, 1.5"
            ,(lambda () (format nil "~D.~D" (random 100 state) (random 100 state)))))))
  (format t "~A ~A, best of ~D, ns per READ-FROM-STRING~%~%"
          (lisp-implementation-type) (lisp-implementation-version) *runs*)
  (format t "~32A ~10@A ~10@A ~10@A~%" "token" "fast off" "fast on" "difference")
  (loop for (name make) in cases
        for v = (coerce (loop repeat n collect (funcall make)) 'simple-vector)
        do (multiple-value-bind (on off) (on-and-off v)
             (format t "~32A ~10,0F ~10,0F ~10@A~%" name off on
                     (format nil "~@D" (round (- on off))))
             (finish-output))))
