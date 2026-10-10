;;;; Exhaustive check: every positive finite SINGLE-FLOAT (2^31 - 2^23 - 1
;;;; values) is printed by FLONUM-TO-DIGITS exactly as by SBCL's original
;;;; Burger-Dybvig printer, loaded from the SBCL source without its zmij
;;;; shortcut. Normal floats must match digit for digit, ties included.
;;;; Subnormals are expected to differ (zmij prints them shorter) and are
;;;; only counted.
;;;;
;;;;   THREADS=16 ~/repos/sbcl-zmij/run-sbcl.sh --script tests/single-all.lisp [start end]
;;;;
;;;; START and END are optional bit patterns (default: all positive finite
;;;; singles, #x00000001 below #x7F800000), so the run can be split up.
;;;; Progress is printed per 1/64 of the range; expect tens of minutes.

(in-package "SB-IMPL")

(load (merge-pathnames "common.lisp" *load-truename*))

;;; src/code/print.lisp of the SBCL running this test.
(defparameter *print-source*
  (namestring (merge-pathnames "../../src/code/print.lisp"
                               (make-pathname :name nil :type nil :defaults sb-ext:*runtime-pathname*))))

;;; %FLONUM-TO-DIGITS without its first form, the #+64-bit zmij shortcut.
(let* ((text (with-open-file (s *print-source*)
               (let ((string (make-string (file-length s))))
                 (subseq string 0 (read-sequence string s)))))
       (start (search "(defun %flonum-to-digits" text))
       (form (let ((*package* (find-package "SB-IMPL"))
                   (*features* (remove :64-bit *features*)))
               (read-from-string text t nil :start start))))
  (eval `(defun reference-flonum-to-digits ,(third form)
           (block %flonum-to-digits ,@(cdddr form))))
  (compile 'reference-flonum-to-digits))

(defun reference-digits (x)
  (let ((s (make-string-output-stream)))
    (reference-flonum-to-digits
     (lambda (d) (write-char (digit-char d) s))
     (lambda (k) k)
     (lambda (k) (values k (get-output-stream-string s)))
     x)))

;;; NIL if X prints the same with both printers, else the list
;;; (X ORIGINAL-K ORIGINAL-DIGITS ZMIJ-K ZMIJ-DIGITS).
(defun digit-mismatch (x)
  (multiple-value-bind (k1 s1) (reference-digits x)
    (multiple-value-bind (k2 s2) (flonum-to-digits x)
      (unless (and (= k1 k2) (string= s1 s2))
        (list x k1 s1 k2 s2)))))

;;; Check the singles with bit patterns from FROM below TO. Return the
;;; mismatches of normal floats, and the number of subnormals that differ.
(defun check-range (from to)
  (loop for bits from from below to
        for mismatch = (digit-mismatch (sb-kernel:make-single-float bits))
        for subnormal = (< bits #x00800000)
        when (and mismatch subnormal) count t into subnormal-differences
        when (and mismatch (not subnormal)) collect mismatch into mismatches
        finally (return (values mismatches subnormal-differences))))

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
(defvar *lock* (sb-thread:make-mutex :name "single-all"))
(defvar *next* *start*)
(defvar *next-report* *report-every*)
(defvar *checked* 0)
(defvar *failures* 0)
(defvar *subnormal-differences* 0)
(defvar *start-time* (get-internal-real-time))

;;; The next chunk of bit patterns, as (VALUES FROM TO), or NIL when none
;;; is left.
(defun take-chunk ()
  (sb-thread:with-mutex (*lock*)
    (when (< *next* *end*)
      (let ((from *next*))
        (setf *next* (min *end* (+ from *chunk*)))
        (values from *next*)))))

;;; Add a checked chunk's results to the totals, print its mismatches,
;;; and print the progress every 1/64 of the range.
(defun record-chunk (from to mismatches subnormal-differences)
  (sb-thread:with-mutex (*lock*)
    (incf *checked* (- to from))
    (incf *subnormal-differences* subnormal-differences)
    (loop for (x k1 s1 k2 s2) in mismatches
          do (cl-user::fail (*failures*)
               "FAIL ~S: original ~D ~S, zmij ~D ~S~%" x k1 s1 k2 s2))
    ;; By the count checked, not by TO: chunks finish out of order.
    (when (>= *checked* *next-report*)
      (incf *next-report* *report-every*)
      (format t "  ~5,1F%  ~:D checked, ~D failure~:P, ~D s~%"
              (* 100 (/ *checked* (- *end* *start*)))
              *checked* *failures*
              (round (- (get-internal-real-time) *start-time*)
                     internal-time-units-per-second))
      (finish-output))))

(defun worker ()
  (loop
    (multiple-value-bind (from to) (take-chunk)
      (unless from (return))
      (multiple-value-bind (mismatches subnormal-differences) (check-range from to)
        (record-chunk from to mismatches subnormal-differences)))))

(let ((n-threads (or (ignore-errors (parse-integer (sb-ext:posix-getenv "THREADS"))) 8)))
  (format t "Checking singles #x~8,'0X below #x~8,'0X on ~D threads~%"
          *start* *end* n-threads)
  (finish-output)
  (mapc #'sb-thread:join-thread
        (loop repeat n-threads collect (sb-thread:make-thread #'worker)))
  (format t "~:D checked; ~:D subnormal difference~:P (expected)~%"
          *checked* *subnormal-differences*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
