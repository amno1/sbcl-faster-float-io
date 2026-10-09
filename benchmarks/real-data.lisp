;;;; Reading and printing real-world floats: the number files of the
;;;; float-data submodule (https://github.com/fastfloat/float-data), one
;;;; number per line. For each file, in ns per number, best of RUNS
;;;; (default 5) passes:
;;;;
;;;;   read         READ-FROM-STRING of each line
;;;;   parse-float  SB-EXT:PARSE-FLOAT of each line (builds that have it)
;;;;   print        PRIN1-TO-STRING of each value
;;;;
;;;; Values are doubles, or singles for the files the data set marks as
;;;; FP32. Every value printed is also read back; a value that does not
;;;; come back as the same float is a failure (exit status 1). Works on any
;;;; SBCL, so stock and patched builds can be compared:
;;;;
;;;;   ~/repos/sbcl-upstream/run-sbcl.sh --script benchmarks/real-data.lisp
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script benchmarks/real-data.lisp
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script benchmarks/real-data.lisp
;;;;
;;;; The printing columns of the zmij build and the reading columns of the
;;;; parse-float build are the "after" numbers; each build has the other
;;;; part unchanged.
;;;;
;;;; Without arguments, all files in ../float-data/number_files are used.
;;;; LIMIT (default 1000000) caps the lines taken from each file.

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 5))

(defparameter *limit*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "LIMIT"))) 1000000))

;;; The float-data files whose values are single-floats (FP32).
(defparameter *single-files* '("marine_ik" "mobilenetv3_large"))

(defparameter *parse-float*
  (let ((s (find-symbol "PARSE-FLOAT" "SB-EXT")))
    (and s (fboundp s) (fdefinition s))))

(defun read-lines (path)
  (with-open-file (in path)
    (coerce (loop for line = (read-line in nil)
                  for i below *limit*
                  while line
                  unless (zerop (length line))
                    collect (coerce line 'simple-string))
            'simple-vector)))

(defun bench (f v)
  "Best of *RUNS* passes, in ns per element of V. A pass goes over V as
many times as needed to make at least 1M calls, so that small files are
timed over more than the clock's resolution."
  (declare (function f) (simple-vector v))
  (let ((repeat (ceiling 1000000 (length v))))
    (loop repeat *runs*
          minimize (progn
                     (sb-ext:gc)
                     (let ((t0 (get-internal-real-time)))
                       (loop repeat repeat
                             do (loop for x across v do (funcall f x)))
                       (/ (* 1d9 (/ (- (get-internal-real-time) t0)
                                    internal-time-units-per-second))
                          (* repeat (length v))))))))

(defvar *failures* 0)

(defun run-file (path)
  (let* ((name (pathname-name path))
         (type (if (member name *single-files* :test #'string=)
                     'single-float
                     'double-float))
         (*read-default-float-format* type)
         (lines (read-lines path))
         ;; The values, as floats: lines such as "0" or "1129" read as
         ;; integers.
         (floats (map 'simple-vector
                      (lambda (s) (coerce (read-from-string s) type))
                      lines))
         (failures 0))
    ;; Printed values must read back as the same float.
    (loop for x across floats
          for string = (prin1-to-string x)
          unless (eql (read-from-string string) x)
            do (when (< (incf failures) 4)
                 (format t "  FAIL ~S printed as ~S~%" x string)))
    (incf *failures* failures)
    (format t "~24A ~10:D ~7A ~8:D ~12@A ~8:D~@[  ~D failures~]~%"
            name (length lines) (if (eq type 'single-float) "single" "double")
            (round (bench #'read-from-string lines))
            (if *parse-float*
                (format nil "~:D" (round (bench *parse-float* lines)))
                "-")
            (round (bench #'prin1-to-string floats))
            (and (plusp failures) failures))
    (finish-output)))

(let* ((args (rest sb-ext:*posix-argv*))
       (here (directory-namestring *load-truename*))
       (files (or args
                  (sort (mapcar #'namestring
                                (directory (concatenate
                                            'string here
                                            "../float-data/number_files/*.txt")))
                        #'string<))))
  (format t "~A ~A, best of ~D, at most ~:D lines per file~%"
          (lisp-implementation-type) (lisp-implementation-version)
          *runs* *limit*)
  (format t "ns per number~%")
  (format t "~24A ~10@A ~7A ~8@A ~12@A ~8@A~%"
          "file" "numbers" "type" "read" "parse-float" "print")
  (dolist (file files)
    (run-file file))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
