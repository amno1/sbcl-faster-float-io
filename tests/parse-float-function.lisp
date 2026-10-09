;;;; Checks SB-EXT:PARSE-FLOAT (branch sbcl-parse-float):
;;;;  1. on valid Lisp float tokens it returns what READ-FROM-STRING returns,
;;;;     bit for bit, or both signal an error;
;;;;  2. it is correctly rounded: the result equals the exact rational value of
;;;;     the string coerced to the float format (also for integer strings,
;;;;     which the reader reads as integers);
;;;;  3. its interface behaves like PARSE-INTEGER's: on integer strings with
;;;;     whitespace, junk, signs, :START/:END, :JUNK-ALLOWED and non-simple
;;;;     strings, both return the same index and the same NIL or error.
;;;;
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script tests/parse-float-function.lisp [count]

(load (merge-pathnames "common.lisp" *load-truename*))

(defvar *failures* 0)
(defvar *checked* 0)

(defun float-key (x)
  (if (floatp x)
      (list (type-of x)
            (etypecase x
              (single-float (sb-kernel:single-float-bits x))
              (double-float (list (sb-kernel:double-float-high-bits x)
                                  (sb-kernel:double-float-low-bits x)))))
      x))

(defun outcome (thunk)
  (handler-case (float-key (funcall thunk))
    (error (c) (list :error (if (typep c 'parse-error) 'parse-error (type-of c))))))

;;; The exact value of a decimal float string (no whitespace or junk) and
;;; its float format, independently of SBCL's parsers.
(defun exact-value (string)
  (let* ((negative (and (plusp (length string)) (char= (char string 0) #\-)))
         (s (string-left-trim "+-" string))
         (epos (position-if (lambda (c) (find (char-upcase c) "ESFDL")) s))
         (mantissa (subseq s 0 epos))
         (exponent (if epos (parse-integer s :start (1+ epos)) 0))
         (format (if epos
                     (ecase (char-upcase (char s epos))
                       (#\E *read-default-float-format*)
                       ((#\S #\F) 'single-float)
                       ((#\D #\L) 'double-float))
                     *read-default-float-format*))
         (dot (position #\. mantissa))
         (digits (remove #\. mantissa))
         (fraction (if dot (- (length mantissa) dot 1) 0))
         (value (* (parse-integer digits) (expt 10 (- exponent fraction)))))
    (values (if negative (- value) value) format)))

(defun check-against-reader (string)
  (incf *checked*)
  (let ((parsed (outcome (lambda () (sb-ext:parse-float string))))
        (read (outcome (lambda () (read-from-string string)))))
    (unless (equal parsed read)
      (fail (*failures*) "FAIL reader ~S (~A): parse-float ~S, reader ~S~%"
            string *read-default-float-format* parsed read))))

(defun check-against-exact (string)
  (incf *checked*)
  (let ((parsed (outcome (lambda () (sb-ext:parse-float string))))
        (exact (outcome (lambda ()
                          (multiple-value-bind (value format) (exact-value string)
                            ;; Too large for the format: PARSE-FLOAT signals a
                            ;; PARSE-ERROR (like the reader).
                            (let ((x (handler-case (coerce value format)
                                       (arithmetic-error ()
                                         (error 'sb-int:simple-parse-error
                                                :format-control "too large")))))
                              ;; -0.0 when the string has a minus sign and
                              ;; the value is zero.
                              (if (and (zerop value) (char= (char string 0) #\-))
                                  (- x)
                                  x)))))))
    (unless (equal parsed exact)
      (fail (*failures*) "FAIL exact ~S (~A): parse-float ~S, exact ~S~%"
            string *read-default-float-format* parsed exact))))

(defun check-like-parse-integer (string &rest args)
  (incf *checked*)
  (flet ((run (fn)
           (handler-case (multiple-value-bind (value index) (apply fn string args)
                           (list (and value t) index))
             (parse-error () :parse-error)
             (error (c) (list :other-error (type-of c))))))
    (let ((float (run #'sb-ext:parse-float))
          (integer (run #'parse-integer)))
      (unless (equal float integer)
        (fail (*failures*) "FAIL interface ~S ~S: parse-float ~S, parse-integer ~S~%"
              string args float integer)))))

(defun random-digits (n state)
  (let ((s (make-string n)))
    (dotimes (i n s)
      (setf (char s i) (digit-char (random 10 state))))))

(defun random-decimal (state)
  (let* ((n (1+ (random (if (zerop (random 4 state)) 25 19) state)))
         (digits (random-digits n state))
         (point (random (1+ n) state))
         (mantissa (concatenate 'string
                                (case (random 3 state) (0 "-") (1 "+") (t ""))
                                (make-string (random 3 state) :initial-element #\0)
                                (subseq digits 0 point) "." (subseq digits point)))
         (marker (char "eEdDfFsSlL" (random 10 state))))
    (if (and (< point n) (zerop (random 3 state)))
        mantissa
        (format nil "~A~C~D" mantissa marker (- (random 801 state) 400)))))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 100000))
      (state (sb-ext:seed-random-state 43)))
  ;; 1 and 2: values.
  (dolist (*read-default-float-format* '(single-float double-float))
    (dolist (s '("0.0" "-0.0" "+0.0" "0.0d0" "-0.0d0" "0e0" "-0e5" ".5" "-.5" "1e5"
                 "1d5" "1f5" "1s5" "1l5" "1.7976931348623157d308"
                 "4.9406564584124654d-324" "2.2250738585072011d-308"
                 "3.4028235e38" "1.4e-45" "9007199254740993.0" "9007199254740993d0"
                 "16777217f0" "0.1" "123.456" "1d23" "1234567890123456789.0"
                 "12345678901234567890.0" "1.2345678901234567890123d0"
                 "0.00000000000000000001234567890123456789"))
      (check-against-reader s)
      (check-against-exact s))
    ;; Integer strings: floats, correctly rounded.
    (dolist (s '("0" "-0" "12" "12." "-12." "+7" "9007199254740993" "16777217"
                 "123456789012345678901234567890" "00012"))
      (check-against-exact s))
    (dotimes (i count)
      (let ((s (random-decimal state)))
        (check-against-reader s)
        (check-against-exact s))
      (let ((x (sb-kernel:make-double-float (- (random (ash 1 31) state))
                                            (random (ash 1 32) state)))
            (f (sb-kernel:make-single-float (- (random (ash 1 31) state)))))
        (dolist (x (list x f (abs x) (abs f)))
          (unless (or (sb-ext:float-nan-p x) (sb-ext:float-infinity-p x))
            (check-against-reader (prin1-to-string x))))))
    ;; Halfway cases near 2^53 and 2^24.
    (loop for k below 2000
          for m = (+ (expt 2 53) 1 (* 2 k))
          for f = (+ (expt 2 24) 1 (* 2 k))
          do
          (dolist (s (list (format nil "~D.0" m) (format nil "~Dd0" m)
                           (format nil "~D.5d0" (floor m 2)) (format nil "~D.0" f)
                           (format nil "~Df0" f)))
               (check-against-reader s)
               (check-against-exact s))))
  ;; 3: interface, on strings that are integers for PARSE-INTEGER too.
  (dolist (s '("12" " 12" "12 " "  12  " "+12" "-12" "1 2" "12x" "x12" "" "   "
               "-" "+" "- 12" "12-" (format nil "~C12~C" #\Tab #\Newline)))
    (check-like-parse-integer s)
    (check-like-parse-integer s :junk-allowed t))
  (dolist (args '((:start 1) (:end 3) (:start 2 :end 4) (:start 0 :end 0)
                  (:start 1 :junk-allowed t) (:end 2 :junk-allowed t)))
    (dolist (s '("  123  " "x123y" "123" " 1 2 3 "))
      (apply #'check-like-parse-integer s args)))
  ;; Non-simple strings.
  (let ((fill (make-array 10 :element-type 'character :fill-pointer 5
                             :initial-contents "  42 junk ")))
    (check-like-parse-integer fill)
    (check-like-parse-integer fill :junk-allowed t))
  (let* ((base (copy-seq "xx 3.25 yy"))
         (displaced (make-array 6 :element-type 'character :displaced-to base
                                  :displaced-index-offset 2)))
    (incf *checked*)
    (multiple-value-bind (value index) (sb-ext:parse-float displaced :junk-allowed t)
      (unless (and (eql value 3.25) (eql index 5))
        (fail (*failures*) "FAIL displaced: ~S ~S~%" value index))))
  ;; Junk-allowed with an exponent marker that is not followed by digits.
  (dolist (case '(("1.5e" 1.5 3) ("1.5ex" 1.5 3) ("2e+" 2.0 1) ("3d-x" 3d0 1)))
    (incf *checked*)
    (destructuring-bind (s value index) case
      (let ((*read-default-float-format* (if (typep value 'double-float)
                                             'double-float 'single-float)))
        (multiple-value-bind (v i) (sb-ext:parse-float s :junk-allowed t)
          (unless (and (eql v (coerce value *read-default-float-format*)) (eql i index))
            (fail (*failures*) "FAIL junk marker ~S: ~S ~S, expected ~S ~S~%" s v i value index))))))
  (format t "~:D checks~%" *checked*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
