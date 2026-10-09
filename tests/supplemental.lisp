;;;; Reading against Nigel Tao's parse-number test data, in the
;;;; supplemental_test_files submodule
;;;; (https://github.com/fastfloat/supplemental_test_files). Each line is
;;;;
;;;;   F16 F32 F64 STRING
;;;;
;;;; the bits of the nearest half, single and double float to the decimal
;;;; STRING, in hex; about 5.3M lines from several sources, many of them
;;;; hard cases (long digit strings, halfway cases, extreme exponents).
;;;; Every STRING is read as a double and as a single, both with
;;;; READ-FROM-STRING and with SB-EXT:PARSE-FLOAT (in builds that have it),
;;;; and the result must have exactly the expected bits. Strings without a
;;;; point or exponent are integers to the reader, so for those only
;;;; PARSE-FLOAT is checked.
;;;;
;;;; A number too large for the format (expected bits: infinity) must
;;;; signal an error, as SBCL's reader does; on platforms that do not trap
;;;; overflow (ARM) an infinity is accepted too. Works on any SBCL:
;;;;
;;;;   sbcl --script tests/supplemental.lisp [file ...]
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script tests/supplemental.lisp [file ...]
;;;;
;;;; Without arguments, all files in supplemental_test_files/data are used.

(defparameter *parse-float*
  (let ((s (find-symbol "PARSE-FLOAT" "SB-EXT")))
    (and s (fboundp s) (fdefinition s))))

(defvar *checks* 0)
(defvar *failures* 0)

(defun float-bits (x)
  (etypecase x
    (double-float (ldb (byte 64 0)
                       (logior (ash (sb-kernel:double-float-high-bits x) 32)
                               (sb-kernel:double-float-low-bits x))))
    (single-float (ldb (byte 32 0) (sb-kernel:single-float-bits x)))))

;;; Check that FUNCTION, reading STRING as TYPE, gives the float with the
;;; bits EXPECTED. EXPONENT-MASK has every exponent bit of TYPE set: an
;;; expected value with all of them set is infinity.
(defun check (name function string type expected exponent-mask)
  (incf *checks*)
  (let* ((overflow (= (logand expected exponent-mask) exponent-mask))
         (result (let ((*read-default-float-format* type))
                   (handler-case (funcall function string)
                     (error (c) c))))
         (ok (cond ((typep result 'condition) overflow)
                   ((not (typep result type)) nil)
                   (overflow (sb-ext:float-infinity-p result))
                   (t (= (float-bits result) expected)))))
    (unless ok
      (when (<= (incf *failures*) 50)
        (format t "FAIL ~A ~(~A~) ~S: expected ~X, got ~A~%"
                name type
                (if (> (length string) 60)
                    (concatenate 'string (subseq string 0 60) "...")
                    string)
                expected
                (if (typep result 'condition)
                    (type-of result)
                    (format nil "~X (~S)" (float-bits result) result)))
        (finish-output)))))

(defun run-file (path)
  (let ((before *checks*)
        (failures-before *failures*))
    (with-open-file (in path)
      (loop for line = (read-line in nil)
            while line
            do (let* ((p1 (position #\Space line))
                      (p2 (position #\Space line :start (1+ p1)))
                      (p3 (position #\Space line :start (1+ p2)))
                      (f32 (parse-integer line :start (1+ p1) :end p2 :radix 16))
                      (f64 (parse-integer line :start (1+ p2) :end p3 :radix 16))
                      (string (subseq line (1+ p3))))
                 ;; Without a point or exponent the reader reads an
                 ;; integer, so only PARSE-FLOAT is checked.
                 (when (find-if (lambda (c) (find c ".eE")) string)
                   (check "read" #'read-from-string string
                          'double-float f64 #x7FF0000000000000)
                   (check "read" #'read-from-string string
                          'single-float f32 #x7F800000))
                 (when *parse-float*
                   (check "parse-float" *parse-float* string
                          'double-float f64 #x7FF0000000000000)
                   (check "parse-float" *parse-float* string
                          'single-float f32 #x7F800000)))))
    (format t "~32A ~12:D checks, ~D failure~:P~%"
            (file-namestring path)
            (- *checks* before)
            (- *failures* failures-before))
    (finish-output)))

(let* ((args (rest sb-ext:*posix-argv*))
       (here (directory-namestring *load-truename*))
       (files (or args
                  (sort (mapcar #'namestring
                                (directory (concatenate
                                            'string here
                                            "../supplemental_test_files/data/*.txt")))
                        #'string<))))
  (format t "~A ~A; sb-ext:parse-float ~:[not present~;present~]~%"
          (lisp-implementation-type)
          (lisp-implementation-version)
          *parse-float*)
  (dolist (file files)
    (run-file file))
  (format t "~:D checks~%~:[OK~;FAILED~]: ~D failure~:P~%"
          *checks* (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
