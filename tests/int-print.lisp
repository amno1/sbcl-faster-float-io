;;;; Checks base-10 integer printing (%OUTPUT-WORD-IN-BASE-10, branch
;;;; sbcl-int-print) against a reference computed here with a plain
;;;; divide-by-10 loop, independent of the printer.
;;;;
;;;; Integers: every power of ten up to 10^80 and its neighbours, the fixnum
;;;; and word limits, random words of every length, bignums whose 19-digit
;;;; chunks are zero or start with zeros, and random bignums of up to 2,048
;;;; bits (32 words, where the chunked printing stops), all with both
;;;; signs. Ways of printing: PRIN1-TO-STRING, PRINC-TO-STRING, PRIN1 to a
;;;; string stream, FORMAT ~D, ~:D, ~10D and ~@D, and *PRINT-RADIX* (a
;;;; trailing point in base 10).
;;;;
;;;;   ~/repos/sbcl-int-print/run-sbcl.sh --script tests/int-print.lisp [count]

(load (merge-pathnames "common.lisp" *load-truename*))

(defvar *failures* 0)
(defvar *checked* 0)

;;; The decimal digits of N, with a minus sign if negative.
(defun reference-digits (n)
  (if (zerop n)
      "0"
      (let ((digits '())
            (m (abs n)))
        (loop until (zerop m)
              do (multiple-value-bind (q r) (truncate m 10)
                   (push (code-char (+ (char-code #\0) r)) digits)
                   (setq m q)))
        (coerce (if (minusp n) (cons #\- digits) digits) 'string))))

;;; The digits with a comma between groups of three, as ~:D prints them.
(defun reference-commas (n)
  (let* ((digits (reference-digits (abs n)))
         (groups (loop for end downfrom (length digits) above 0 by 3
                       collect (subseq digits (max 0 (- end 3)) end))))
    (format nil "~:[~;-~]~{~A~^,~}" (minusp n) (reverse groups))))

(defun check (n)
  (let ((digits (reference-digits n)))
    (flet ((expect (name got expected)
             (incf *checked*)
             (unless (string= got expected)
               (cl-user::fail (*failures*)
                 "FAIL ~A of ~D: got ~S, expected ~S~%" name n got expected))))
      (expect "prin1-to-string" (prin1-to-string n) digits)
      (expect "princ-to-string" (princ-to-string n) digits)
      (expect "prin1 to a stream" (with-output-to-string (s) (prin1 n s)) digits)
      (expect "~D" (format nil "~D" n) digits)
      (expect "~:D" (format nil "~:D" n) (reference-commas n))
      (expect "~10D" (format nil "~10D" n)
              (format nil "~10@A" digits))
      (expect "~@D" (format nil "~@D" n)
              (if (minusp n) digits (concatenate 'string "+" digits)))
      (expect "*print-radix*" (let ((*print-radix* t)) (prin1-to-string n))
              (concatenate 'string digits ".")))))

(let* ((count (if (second sb-ext:*posix-argv*)
                  (parse-integer (second sb-ext:*posix-argv*))
                  200000))
       (state (sb-ext:seed-random-state 23))
       (specials (list 0 most-positive-fixnum most-negative-fixnum
                       (1+ most-positive-fixnum) (1- most-negative-fixnum)
                       (1- (expt 2 64)) (expt 2 64) (1+ (expt 2 64))
                       (1- (expt 2 63)) (expt 2 63))))
  ;; Powers of ten and their neighbours, both signs.
  (do-combinations ((k (range 0 80))
                    (n (list (1- (expt 10 k)) (expt 10 k) (1+ (expt 10 k)))))
    (check n)
    (check (- n)))
  (dolist (n specials)
    (check n)
    (check (- n)))
  ;; Bignums whose 19-digit chunks are zero, or start with zeros: K times
  ;; 10^(19 * C) plus a small number, for several K and C.
  (do-combinations ((c (range 1 6))
                    (k '(1 7 99 12345 9999999999999999999))
                    (small '(0 1 10 123456789)))
    (let ((n (+ (* k (expt 10 (* 19 c))) small)))
      (check n)
      (check (- n))))
  ;; Random bignums of up to 2,048 bits.
  (dotimes (i (floor count 20))
    (let ((n (random (ash 1 (+ 65 (random 1984 state))) state)))
      (check n)
      (check (- n))))
  ;; Random words of every length: N below 2^BITS, for random BITS.
  (dotimes (i count)
    (let ((n (random (ash 1 (1+ (random 64 state))) state)))
      (check n)
      (check (- n))))
  (format t "~:D checks~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
