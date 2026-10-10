;;;; Correctness tests for SBCL's zmij-based shortest float printer.
;;;;
;;;; Checks every result against an exact, algorithm-independent oracle
;;;; built from rational arithmetic:
;;;;   1. round-trip:  the printed digits read back as the same float;
;;;;   2. shortest:    no decimal with fewer digits round-trips;
;;;;   3. closest:     among decimals of the same length, none is nearer.
;;;;
;;;; Run with an SBCL built with zmij:
;;;;   ../sbcl/run-sbcl.sh --script tests/correctness.lisp [random|edge|single-all] [count]

(in-package "CL-USER")

(load (merge-pathnames "common.lisp" *load-truename*))

(defun digits (f)
  "Return (values k digit-string) from SBCL's printer for positive F."
  (sb-impl::flonum-to-digits f))

;; f: the float being checked, a single or a double, made positive by the caller.
;; d: the candidate decimal’s digits as an integer, without the decimal point. 
;; e: a power-of-ten exponent, so the candidate’s value is exactly d × 10^e.

;; For example, if the printer gives the digits "15" with k = 0 for 0.15, check
;; passes d = 15 and e = k − n = 0 − 2 = −2, so the candidate is 15 × 10^−2 =
;; 0.15. In scientific notation that would be 1.5e−1. Here e is the exponent of
;; the last digit, which is why it’s −2 and not −1.

;; What it checks: whether the decimal d × 10^e reads back as f.

;; (* d (expt 10 e)) is computed exactly, as an integer or a ratio, with no
;; rounding.  coerce to f’s type rounds that exact value once, to the nearest
;; float. That’s what reading the decimal back would give.  = then checks
;; whether that float is f.

;; So no printing or reading code takes part, which is why the test can serve as
;; an independent reference. It relies only on SBCL’s coerce from rationals
;; rounding correctly.

;; The two guards:

;; (plusp d): the callers also try nearby candidates like (floor q), which can
;; be 0 for small values. A zero candidate is never a valid representation of a
;; positive float, so it’s rejected up front.  floating-point-overflow -> NIL: a
;; candidate such as (ceiling q) near most-positive-double-float can be larger
;; than the biggest float, and then coerce signals overflow. Such a candidate
;; doesn’t round-trip, so the error is treated as “no”.

;; check uses it three ways:

;; round-trip: the printed digits themselves must pass; shortest: no candidate
;; with one or two digits fewer may pass; closest: if both neighbours (floor q)
;; and (ceiling q) at the same length pass, the printed d must not be farther
;; from the true value than the nearer of them.

(defun candidate-ok-p (f d e)
  (and (plusp d)
       (handler-case (= f (coerce (* d (expt 10 e)) (type-of f)))
         (floating-point-overflow () nil))))

(defun check (f)
  "Return NIL if F prints correctly, otherwise a string describing the problem."
  (let ((f (abs f)))
    (multiple-value-bind (k s) (digits f)
      (let* ((n (length s))
             (d (parse-integer s))
             (e (- k n))
             (r (rational f)))
        (cond
          ((char= (char s (1- n)) #\0)
           (format nil "trailing zero: ~S" s))
          ((not (candidate-ok-p f d e))
           (format nil "does not round-trip: ~Ae~D" s e))
          ;; Any shorter representation, padded, is an (n-1)-digit one at
          ;; one of these scales.
          ((and (> n 1)
                (loop for e2 in (list (1+ e) (+ e 2))
                      for q = (/ r (expt 10 e2))
                      thereis (or (candidate-ok-p f (floor q) e2)
                                  (candidate-ok-p f (ceiling q) e2))))
           (format nil "not shortest: ~A" s))
          ((let* ((q (/ r (expt 10 e)))
                  (best (min (abs (- q (floor q))) (abs (- q (ceiling q))))))
             (and (candidate-ok-p f (floor q) e)
                  (candidate-ok-p f (ceiling q) e)
                  (> (abs (- q d)) best)))
           (format nil "not closest: ~A" s))
          (t nil))))))

(defun check-print (f)
  "Return NIL if PRIN1 of F reads back as F, otherwise a description."
  (let* ((string (prin1-to-string f))
         (back (let ((*read-default-float-format* 'single-float))
                 (read-from-string string))))
    (unless (eql back f)
      (format nil "prin1 gave ~S, reads back as ~S" string back))))

(defvar *failures* 0)

(defun test (f)
  (unless (or (sb-ext:float-infinity-p f) (sb-ext:float-nan-p f) (zerop f))
    (let ((problem (or (check f)
                       (check-print f))))
      (when (and problem
                 (< (incf *failures*) 50))
        (format t "FAIL ~S: ~A~%" f problem)))))

(defun random-double (state)
  (sb-kernel:make-double-float (- (random (ash 1 32) state) (ash 1 31))
                               (random (ash 1 32) state)))

(defun random-single (state)
  (sb-kernel:make-single-float (- (random (ash 1 32) state) (ash 1 31))))

(defun run-random (count)
  (let ((state (sb-ext:seed-random-state 42)))
    (dotimes (i count)
      (test (random-double state))
      (test (random-single state)))))

(defun run-edge ()
  ;; Every exponent, with minimal, maximal and near-boundary significands.
  (do-combinations ((e (range 0 2046))
                    (lo '(0 1 2 #xFFFFFFFF))
                    (hi '(0 1 #xFFFFF)))
    (test (sb-kernel:make-double-float (logior (ash e 20) hi) lo)))
  (do-combinations ((e (range 0 254))
                    (sig '(0 1 2 #x7FFFFF #x400000)))
    (test (sb-kernel:make-single-float (logior (ash e 23) sig))))
  ;; Every double and single subnormal near the bottom.
  (loop for i from 1 to 100000
        do (test (sb-kernel:make-double-float 0 i))
           (test (sb-kernel:make-single-float i)))
  ;; Integers, decimal fractions and powers of ten.
  (loop for i from 1 to 100000
        do (test (float i 1d0)) (test (float i 1f0))
           (test (/ i 1000d0)) (test (/ i 1000f0)))
  (loop for p from -330 to 308
        do (let ((r (expt 10 p)))
             (test (coerce r 'double-float))
             (when (< -46 p 39) (test (coerce r 'single-float)))))
  (dolist (f (list least-positive-double-float most-positive-double-float
                   least-positive-normalized-double-float
                   least-positive-single-float most-positive-single-float
                   least-positive-normalized-single-float
                   0.1d0 0.2d0 0.3d0 1d23 9007199254740993d0 5d-324
                   0.1 0.3 1e10 123456.7 16777216.0))
    (test f)))

;;; Check the single-floats with bit patterns from START below END, out of
;;; all of them, below LIMIT; print failures and the progress under LOCK.
(defun check-singles (start end limit lock)
  (loop for bits from start below end
        for f = (sb-kernel:make-single-float bits)
        for problem = (check f)
        when problem
          do (sb-thread:with-mutex (lock)
               (fail (*failures*) "FAIL ~S: ~A~%" f problem))
        when (zerop (mod bits #x1000000))
          do (sb-thread:with-mutex (lock)
               (format t "  ~,1F%~%" (* 100 (/ bits limit)))
               (finish-output))))

(defun run-single-all ()
  "Every positive finite single-float, in parallel. Takes a while."
  (let* ((n-threads (max 1 (or (ignore-errors
                                (parse-integer (sb-ext:posix-getenv "THREADS")))
                               8)))
         (limit #x7F800000)
         (chunk (ceiling limit n-threads))
         (lock (sb-thread:make-mutex)))
    (mapc #'sb-thread:join-thread
          (loop for i below n-threads
                collect (sb-thread:make-thread
                         #'check-singles
                         :arguments (list (max 1 (* i chunk))
                                          (min limit (* (1+ i) chunk))
                                          limit lock))))))

(let* ((args (rest sb-ext:*posix-argv*))
       (mode (or (first args) "all"))
       (count (if (second args)
                  (parse-integer (second args))
                  1000000)))
  (format t "mode ~A~%" mode)
  (cond ((string= mode "random")
         (run-random count))
        ((string= mode "edge")
         (run-edge))
        ((string= mode "single-all")
         (run-single-all))
        (t
         (run-edge)
         (run-random count)))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
