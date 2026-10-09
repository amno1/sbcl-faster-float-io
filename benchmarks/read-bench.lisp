;;;; How the time of reading a float splits: READ-FROM-STRING of float tokens
;;;; of three shapes, and the conversion step alone, (COERCE (/ NUMBER
;;;; DIVISOR) 'DOUBLE-FLOAT) with the NUMBER and DIVISOR that MAKE-FLOAT in
;;;; src/code/reader.lisp computes. Reading a 16-digit integer gives the cost
;;;; of the reader machinery itself. Best of RUNS (default 7) passes over
;;;; 100k tokens. Works on any SBCL:
;;;;
;;;;   sbcl --script benchmarks/read-bench.lisp
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script benchmarks/read-bench.lisp

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

;;; NUMBER and DIVISOR as MAKE-FLOAT computes them, for a positive decimal
;;; token with an optional exponent.
(defun make-float-parts (string)
  (let* ((epos (position-if (lambda (c) (find c "dDeEfFsSlL")) string))
         (mantissa (subseq string 0 epos))
         (exponent (if epos (parse-integer string :start (1+ epos)) 0))
         (dot (position #\. mantissa))
         (digits (remove #\. mantissa))
         (fraction-digits (if dot (- (length mantissa) dot 1) 0))
         (number (parse-integer digits)))
    (if (>= exponent 0)
        (list (* number (expt 10 exponent)) (expt 10 fraction-digits))
        (list number (* (expt 10 fraction-digits) (expt 10 (- exponent)))))))

(let* ((state (sb-ext:seed-random-state 5))
       (n 100000)
       (*read-default-float-format* 'double-float)
       (sets
         (list
          (cons "short (e.g. 1.5, 12.25)"
                (loop repeat n
                      collect (format nil "~D.~D" (random 1000 state) (random 100 state))))
          (cons "17 digits, ordinary"
                (loop repeat n
                      collect (prin1-to-string
                               (* (random 1d0 state) (expt 10d0 (random 8 state))))))
          (cons "17 digits, exponent up to 300"
                (loop repeat n
                      collect (prin1-to-string
                               (* (random 1d0 state)
                                  (expt 10d0 (- (random 600 state) 300))))))))
       (integers (coerce (loop repeat n
                               collect (format nil "~D" (random (expt 10 16) state)))
                         'simple-vector)))
  (format t "~A ~A, best of ~D~%" (lisp-implementation-type)
          (lisp-implementation-version) *runs*)
  (format t "~40A ~8,1F ns~%" "read-from-string of a 16-digit integer"
          (bench #'read-from-string integers))
  (dolist (set sets)
    (let* ((strings (coerce (cdr set) 'simple-vector))
           (parts (map 'simple-vector #'make-float-parts strings)))
      (format t "~A~%" (car set))
      (format t "  ~38A ~8,1F ns~%" "read-from-string"
              (bench #'read-from-string strings))
      (format t "  ~38A ~8,1F ns~%" "conversion (coerce (/ n d) 'double-float)"
              (bench (lambda (p) (coerce (/ (first p) (second p)) 'double-float))
                     parts)))))

;;; Same build, fast path on and off.
(let ((fast-path (find-symbol "MAKE-FLOAT/FAST" "SB-IMPL")))
  (when (and fast-path (fboundp fast-path))
    (sb-ext:without-package-locks
      (let* ((state (sb-ext:seed-random-state 5))
             (n 100000)
             (*read-default-float-format* 'double-float)
             (original (fdefinition fast-path))
             (sets
               (list
                (cons "short (1.5, 12.25)"
                      (loop repeat n collect (format nil "~D.~D" (random 1000 state)
                                                     (random 100 state))))
                (cons "17 digits, ordinary"
                      (loop repeat n collect (prin1-to-string
                                              (* (random 1d0 state)
                                                 (expt 10d0 (random 8 state))))))
                (cons "17 digits, exponent to 300"
                      (loop repeat n collect (prin1-to-string
                                              (* (random 1d0 state)
                                                 (expt 10d0 (- (random 600 state) 300))))))
                (cons "single floats"
                      (loop repeat n collect (prin1-to-string
                                              (coerce (* (random 1d0 state)
                                                         (expt 10d0 (- (random 60 state) 30)))
                                                      'single-float)))))))
        (format t "~%Same build, fast path on and off:~%")
        (unwind-protect
             (dolist (set sets)
               (let ((strings (coerce (cdr set) 'simple-vector)))
                 (setf (fdefinition fast-path) original)
                 (let ((fast (bench #'read-from-string strings)))
                   (setf (fdefinition fast-path) (constantly nil))
                   (format t "  ~28A fast path ~7,1F ns   original ~7,1F ns~%"
                           (car set) fast (bench #'read-from-string strings)))))
          (setf (fdefinition fast-path) original))))))

;;; SB-EXT:PARSE-FLOAT against READ-FROM-STRING, on builds that have it.
(let ((parse-float (find-symbol "PARSE-FLOAT" "SB-EXT")))
  (when (and parse-float (fboundp parse-float))
    (let* ((state (sb-ext:seed-random-state 5))
           (n 100000)
           (*read-default-float-format* 'double-float)
           (sets
             (list
              (cons "short (1.5, 12.25)"
                    (loop repeat n collect (format nil "~D.~D" (random 1000 state)
                                                   (random 100 state))))
              (cons "17 digits, ordinary"
                    (loop repeat n collect (prin1-to-string
                                            (* (random 1d0 state)
                                               (expt 10d0 (random 8 state))))))
              (cons "17 digits, exponent to 300"
                    (loop repeat n collect (prin1-to-string
                                            (* (random 1d0 state)
                                               (expt 10d0 (- (random 600 state) 300))))))
              (cons "single floats"
                    (loop repeat n collect (prin1-to-string
                                            (coerce (* (random 1d0 state)
                                                       (expt 10d0 (- (random 60 state) 30)))
                                                    'single-float)))))))
      (format t "~%SB-EXT:PARSE-FLOAT against READ-FROM-STRING:~%")
      (dolist (set sets)
        (let ((strings (coerce (cdr set) 'simple-vector)))
          (format t "  ~28A parse-float ~7,1F ns   read-from-string ~7,1F ns~%"
                  (car set) (bench (fdefinition parse-float) strings)
                  (bench #'read-from-string strings)))))))
