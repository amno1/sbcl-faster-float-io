;;;; Checks the fixed-position fast path of FLONUM-TO-DIGITS (used by ~F,
;;;; ~E, ~G and ~$), with absolute and relative positions, against SBCL's
;;;; original %FLONUM-TO-DIGITS, loaded from the SBCL source. The two must agree exactly, digit for digit and
;;;; on the decimal point position.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/fixed.lisp [count]

(in-package "SB-IMPL")

;;; src/code/print.lisp of the SBCL running this test.
(defparameter *print-source*
  (namestring (merge-pathnames "../../src/code/print.lisp"
                               (make-pathname :name nil :type nil :defaults sb-ext:*runtime-pathname*))))

;;; The original algorithm, as REFERENCE-DIGITS. With a POSITION argument
;;; its zmij shortcut does not apply, so this is pure Burger-Dybvig.
(let* ((text (with-open-file (s *print-source*)
               (let ((string (make-string (file-length s))))
                 (subseq string 0 (read-sequence string s)))))
       (start (search "(defun %flonum-to-digits" text))
       (form (let ((*package* (find-package "SB-IMPL")))
               (read-from-string text t nil :start start))))
  ;; Keep the original block name for its RETURN-FROM.
  (eval `(defun reference-flonum-to-digits ,(third form)
           (block %flonum-to-digits ,@(cdddr form)))))

(defun reference-digits (x position relativep)
  (let ((s (make-string-output-stream)))
    (reference-flonum-to-digits
     (lambda (d) (write-char (digit-char d) s))
     (lambda (k) k)
     (lambda (k) (values k (get-output-stream-string s)))
     x position relativep)))

(defvar *failures* 0)
(defvar *checked* 0)
(defvar *fast* 0)

(defun test (x position &optional relativep)
  (unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x) (zerop x)
              (and relativep (< position 1)))
    (incf *checked*)
    (when (flonum-to-digits/position
           (abs x) (if relativep (flonum-relative-position (abs x) position) position))
      (incf *fast*))
    (multiple-value-bind (k1 s1) (reference-digits (abs x) position relativep)
      (multiple-value-bind (k2 s2) (flonum-to-digits (abs x) position relativep)
        (unless (and (eql k1 k2) (string= s1 s2))
          (when (< (incf *failures*) 30)
            (format t "FAIL ~S position ~D~:[~; relative~]: expected ~D ~S, got ~D ~S~%"
                    x position relativep k1 s1 k2 s2)))))))

;;; Both modes: absolute POSITION, and relative 1..20 digits.
(defun test-both (x position)
  (test x position)
  (test x (1+ (mod (abs position) 20)) t))

(defun random-double (state)
  (sb-kernel:make-double-float (- (random (ash 1 32) state) (ash 1 31))
                               (random (ash 1 32) state)))

(defun random-single (state)
  (sb-kernel:make-single-float (- (random (ash 1 32) state) (ash 1 31))))

;;; A float of "ordinary" magnitude, where ~,2F and the like are used.
(defun random-ordinary (state)
  (* (if (zerop (random 2 state)) 1 -1)
     (expt 10d0 (- (random 16d0 state) 6))))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 100000))
      (state (sb-ext:seed-random-state 5)))
  ;; Exact ties and near-ties: n/2^k and decimal values with few digits.
  (loop for n from 1 to 4000
        do (dolist (x (list (/ n 8d0) (/ n 8f0) (/ n 1000d0) (/ n 100f0)
                            (+ n 0.5d0) (+ n 0.5f0) (* n 0.005d0) (* n 0.05f0)
                            (- 1 (/ 1d0 n)) (* n 1.005d0)))
             (loop for position from -6 to 3 do (test-both x position))))
  ;; Odd significands whose rounding-interval endpoints (midpoints between
  ;; floats) are short decimals: doubles from 2^53 up, singles from 2^24
  ;; up, where midpoints are integers. Fine positions use the float's own
  ;; interval, closed; this is where "closed" matters.
  (loop for e from 1 to 12
        do (loop for j from 0 below 400
                 for f = (+ (ash 1 52) 1 (* 2 j) (* 2 (random (ash 1 40) state)))
                 do (loop for position from -3 to 6
                          do (test-both (scale-float (float f 1d0) e) position))))
  (loop for e from 1 to 12
        do (loop for j from 0 below 400
                 for f = (+ (ash 1 23) 1 (* 2 (random (ash 1 21) state)))
                 do (loop for position from -3 to 6
                          do (test-both (scale-float (float f 1f0) e) position))))
  ;; Values below one unit at the position: rounding to zero (digits "0")
  ;; and up to one unit, around half a unit, at positions below and at or
  ;; above zero.
  (loop for position from -12 to 3
        do (dolist (factor '(1d-9 1d-3 0.1d0 0.3d0 0.49d0 0.4999999d0 0.5000001d0
                             0.51d0 0.7d0 0.99d0 0.9999999d0))
             (let ((x (* factor (expt 10d0 position))))
               (test-both x position)
               (test-both (coerce x 'single-float) position)
               (test-both (* x (1+ (random 1d-3 state))) position))))
  (dotimes (i 200000)
    (let ((position (- (random 15 state) 12)))
      (test-both (* (random 1d0 state) (expt 10d0 position)) position)))
  ;; Exact ties (q + 1/2 units) at positions 0 to 4, where q can be a
  ;; multiple of 10 (the original then rounds down to the shorter q).
  (loop for position from 0 to 4
        do (loop for q from 1 to 400
                 do (dolist (q (list q (* 10 q) (+ (* 10 q) 9)))
                      (let ((x (* (+ q 1/2) (expt 10 position))))
                        (test-both (coerce x 'double-float) position)
                        (when (< x (expt 2 24))
                          (test-both (coerce x 'single-float) position))))))
  ;; Rounding across a power of ten, and values near one unit.
  (dolist (x (list 9.995d0 9.996d0 99.95d0 0.0095d0 0.995 0.9999999d0
                   0.01d0 0.015d0 0.005d0 0.001 1d0 1.0 0.5d0 0.05d0))
    (loop for position from -10 to 3 do (test-both x position)))
  ;; Random values of ordinary magnitude with typical precisions, and
  ;; random bit patterns with any precision.
  (dotimes (i count)
    (let ((x (random-ordinary state)))
      (test-both x (- (random 8 state)))
      (test-both (coerce x 'single-float) (- (random 8 state))))
    (test-both (random-double state) (- (random 700 state) 350))
    (test-both (random-single state) (- (random 100 state) 50)))
  (format t "~:D checked, ~:D on the fast path~%" *checked* *fast*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
