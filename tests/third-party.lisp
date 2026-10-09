;;;; SB-EXT:PARSE-FLOAT against two libraries that parse floats from
;;;; strings: PARSE-FLOAT (PARSE-FLOAT:PARSE-FLOAT, Sumant Oemrawsingh) and
;;;; PARSE-NUMBER (PARSE-NUMBER:PARSE-NUMBER, sharplispers).
;;;;
;;;; Correctness: N random finite doubles (default 1,000,000, both signs,
;;;; subnormals included) and N random finite singles are printed with
;;;; PRIN1-TO-STRING and parsed by all three. Each result must be the
;;;; original float, bit for bit; an error counts as a failure. The
;;;; libraries' failures are only counted and shown; the script exits 1
;;;; only if SB-EXT:PARSE-FLOAT fails.
;;;;
;;;; Speed: best of RUNS (default 7) passes over 100k strings of the shapes
;;;; used in read-bench.lisp, in ns per string, READ-FROM-STRING included.
;;;;
;;;; Loads the libraries with Quicklisp (they must be installed).
;;;;
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script tests/third-party.lisp [n]

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((*standard-output* (make-broadcast-stream)))
  (funcall (intern "QUICKLOAD" "QL") '("parse-float" "parse-number") :silent t))

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 7))

(defun bench (f v)
  (declare (function f) (simple-vector v))
  (funcall f (aref v 0))
  (loop repeat *runs*
        minimize (progn
                   (sb-ext:gc)
                   (let ((t0 (get-internal-real-time)))
                     (loop for x across v do (funcall f x))
                     (/ (* 1d9 (/ (- (get-internal-real-time) t0)
                                  internal-time-units-per-second))
                        (length v))))))

;;; Random finite floats, both signs, subnormals included. The NaN and
;;; infinity exponent patterns are rejected before the float is made.
(defun random-double (state)
  (loop for high = (- (random (ash 1 32) state) (ash 1 31))
        unless (= (ldb (byte 11 20) high) #x7FF)
          do (return (sb-kernel:make-double-float
                      high (random (ash 1 32) state)))))

(defun random-single (state)
  (loop for bits = (random (ash 1 32) state)
        unless (= (ldb (byte 8 23) bits) #xFF)
          do (return (sb-kernel:make-single-float
                      (if (logbitp 31 bits) (- bits (ash 1 32)) bits)))))

(defparameter *parsers*
  (list (cons "sb-ext:parse-float" (lambda (s) (sb-ext:parse-float s)))
        (cons "parse-float" (lambda (s) (parse-float:parse-float s)))
        (cons "parse-number" (lambda (s) (parse-number:parse-number s)))))

(defvar *own-failures* 0)

;;; Print N random floats of FORMAT and parse them back with every parser.
(defun round-trip (n format make state)
  (let ((*read-default-float-format* format)
        (failures (make-list (length *parsers*) :initial-element 0)))
    (loop repeat n
          do (let* ((x (funcall make state))
                    (string (prin1-to-string x)))
               (loop for (name . parse) in *parsers*
                     for cell on failures
                     do (let ((y (handler-case (funcall parse string)
                                   (error (c) c))))
                          (unless (eql y x)
                            (when (<= (incf (car cell)) 3)
                              (format t "  ~A ~S gave ~S~%" name string
                                      (if (typep y 'condition)
                                          (type-of y)
                                          y))))))))
    (incf *own-failures* (first failures))
    failures))

(let* ((args (rest sb-ext:*posix-argv*))
       (n (if (first args) (parse-integer (first args)) 1000000))
       (state (sb-ext:seed-random-state 7)))
  (format t "Round trip, ~:D random floats of each format~%" n)
  (finish-output)
  (let ((doubles (round-trip n 'double-float #'random-double state))
        (singles (round-trip n 'single-float #'random-single state)))
    (format t "~%~22A ~16@A ~16@A~%" "failures" "doubles" "singles")
    (loop for (name) in *parsers*
          for d in doubles
          for s in singles
          do (format t "~22A ~16:D ~16:D~%" name d s)))
  (format t "~%Speed, ns per string, best of ~D~%" *runs*)
  (format t "~32A~{ ~20@A~}~%" ""
          (append (mapcar #'car *parsers*) '("read-from-string")))
  (flet ((digits17 (s)
           ;; A double with 17 significant digits in [1, 1000).
           (let ((*read-default-float-format* 'double-float))
             (format nil "~,14F" (+ 1 (random 999d0 s)))))
         (digits17-exp (s)
           (format nil "~D.~16,'0De~D" (1+ (random 9 s))
                   (random (expt 10 16) s) (- (random 601 s) 300))))
    (loop for (name format make)
            in `(("short (1.5, 12.25)" double-float
                  ,(lambda (s) (format nil "~D.~D" (random 100 s) (random 100 s))))
                 ("17 digits, ordinary" double-float ,#'digits17)
                 ("17 digits, exponent to +-300" double-float ,#'digits17-exp)
                 ("single-floats" single-float
                  ,(lambda (s)
                     (let ((*read-default-float-format* 'single-float))
                       (prin1-to-string (abs (random-single s)))))))
          do (let ((*read-default-float-format* format)
                   (v (coerce (loop repeat 100000 collect (funcall make state))
                              'simple-vector)))
               (format t "~32A~{ ~20:D~}~%" name
                       ;; Errors are caught for every parser alike, so a
                       ;; library that fails on some strings still gets
                       ;; timed; the round trip above counts its failures.
                       (loop for parse
                               in (append (mapcar #'cdr *parsers*)
                                          (list #'read-from-string))
                             collect (let ((parse parse))
                                       (round (bench (lambda (s)
                                                (handler-case (funcall parse s)
                                                  (error () nil)))
                                              v)))))
               (finish-output))))
  (format t "~%~:[OK~;FAILED~]: sb-ext:parse-float, ~D failure~:P~%"
          (plusp *own-failures*) *own-failures*)
  (sb-ext:exit :code (if (plusp *own-failures*) 1 0)))
