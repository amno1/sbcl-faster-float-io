;;;; Exhaustive round trip: every positive finite SINGLE-FLOAT (2^31 - 2^23 - 1
;;;; values) is printed with PRIN1-TO-STRING and read back with both
;;;; READ-FROM-STRING and SB-EXT:PARSE-FLOAT. Both must give back the same
;;;; float, bit for bit. This checks the zmij printer and the Eisel-Lemire
;;;; reader together, on a build that has both (e.g. ~/repos/sb-simd-512).
;;;; Optionally also N random doubles (DOUBLES, default 0).
;;;;
;;;;   THREADS=16 DOUBLES=100000000 ~/repos/sb-simd-512/run-sbcl.sh \
;;;;     --script tests/single-roundtrip.lisp [start end]
;;;;
;;;; START and END are optional hex bit patterns (default: all positive
;;;; finite singles, #x00000001 below #x7F800000), so the run can be split.
;;;; Negative floats print as "-" followed by the positive form, so only
;;;; positive ones are enumerated. Progress is printed per 1/64 of the range.

(load (merge-pathnames "common.lisp" *load-truename*))

;;; The range to check, from the command line, and the state the threads
;;; share. Global, so that every thread sees the same values; changed only
;;; with *LOCK* held.
(defparameter *start*
  (let ((arg (second sb-ext:*posix-argv*)))
    (if arg (parse-integer arg :radix 16) 1)))
(defparameter *end*
  (let ((arg (third sb-ext:*posix-argv*)))
    (if arg (parse-integer arg :radix 16) #x7F800000)))
(defparameter *chunk* (expt 2 20))
(defparameter *report-every* (max 1 (floor (- *end* *start*) 64)))
(defvar *lock* (sb-thread:make-mutex :name "single-roundtrip"))
(defvar *next* *start*)
(defvar *next-report* *report-every*)
(defvar *checked* 0)
(defvar *failures* 0)
(defvar *start-time* (get-internal-real-time))

(defun report-failure (control &rest args)
  (sb-thread:with-mutex (*lock*)
    (fail (*failures*) "~?" control args)))

;;; X printed and read back must be X, through the reader and through
;;; PARSE-FLOAT.
(defun check (x)
  (let* ((string (prin1-to-string x))
         (read (handler-case (read-from-string string)
                 (error (c) c)))
         (parsed (handler-case (sb-ext:parse-float string)
                   (error (c) c))))
    (unless (eql read x)
      (report-failure "FAIL read ~S: ~S gave ~S~%" x string read))
    (unless (eql parsed x)
      (report-failure "FAIL parse-float ~S: ~S gave ~S~%" x string parsed))))

;;; The next chunk of bit patterns, as (VALUES FROM TO), or NIL when none
;;; is left.
(defun take-chunk ()
  (sb-thread:with-mutex (*lock*)
    (when (< *next* *end*)
      (let ((from *next*))
        (setf *next* (min *end* (+ from *chunk*)))
        (values from *next*)))))

;;; Add a checked chunk to the count, and print the progress every 1/64 of
;;; the range.
(defun record-chunk (from to)
  (sb-thread:with-mutex (*lock*)
    (incf *checked* (- to from))
    ;; By the count checked, not by TO: chunks finish out of order.
    (when (>= *checked* *next-report*)
      (incf *next-report* *report-every*)
      (format t "  ~5,1F%  ~:D singles, ~D failure~:P, ~D s~%"
              (* 100 (/ *checked* (- *end* *start*)))
              *checked* *failures*
              (round (- (get-internal-real-time) *start-time*)
                     internal-time-units-per-second))
      (finish-output))))

(defun single-worker ()
  (let ((*read-default-float-format* 'single-float))
    (loop
      (multiple-value-bind (from to) (take-chunk)
        (unless from (return))
        (loop for bits from from below to
              do (check (sb-kernel:make-single-float bits)))
        (record-chunk from to)))))

;;; A random finite double, of either sign, subnormals included: random
;;; bits, drawn again while the exponent is all ones (infinity or NaN).
(defun random-finite-double (state)
  (loop for high = (- (random (ash 1 32) state) (ash 1 31))
        unless (= (ldb (byte 11 20) high) #x7FF)
          return (sb-kernel:make-double-float high (random (ash 1 32) state))))

(defun double-worker (count seed)
  (let ((*read-default-float-format* 'double-float)
        (state (sb-ext:seed-random-state seed)))
    (loop repeat count
          do (check (random-finite-double state)))))

(let ((n-threads (or (ignore-errors (parse-integer (sb-ext:posix-getenv "THREADS"))) 8))
      (n-doubles (or (ignore-errors (parse-integer (sb-ext:posix-getenv "DOUBLES"))) 0)))
  (format t "Round trip of singles #x~8,'0X below #x~8,'0X on ~D threads~%"
          *start* *end* n-threads)
  (finish-output)
  (mapc #'sb-thread:join-thread
        (loop repeat n-threads
              collect (sb-thread:make-thread #'single-worker)))
  (when (plusp n-doubles)
    (format t "~:D random doubles on ~D threads~%" n-doubles n-threads)
    (finish-output)
    (mapc #'sb-thread:join-thread
          (loop for i below n-threads
                collect (sb-thread:make-thread
                         #'double-worker
                         :arguments (list (ceiling n-doubles n-threads) (+ 1000 i))))))
  (format t "~:D singles~@[ and ~:D doubles~] checked~%" *checked*
          (and (plusp n-doubles) n-doubles))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
