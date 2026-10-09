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

(let* ((args (rest sb-ext:*posix-argv*))
       (start (if (first args) (parse-integer (first args) :radix 16) 1))
       (end (if (second args) (parse-integer (second args) :radix 16) #x7F800000))
       (n-threads (or (ignore-errors (parse-integer (sb-ext:posix-getenv "THREADS"))) 8))
       (lock (sb-thread:make-mutex :name "single-all"))
       (failures 0)
       (subnormal-differences 0)
       (checked 0)
       (next start)
       (chunk (expt 2 20))
       (report-every (max 1 (floor (- end start) 64)))
       (next-report (+ start report-every))
       (start-time (get-internal-real-time)))
  (format t "Checking singles #x~8,'0X below #x~8,'0X on ~D threads~%"
          start end n-threads)
  (finish-output)
  (flet ((worker ()
           (loop
             (let (from to)
               ;; Take the next chunk of bit patterns.
               (sb-thread:with-mutex (lock)
                 (when (>= next end) (return))
                 (setq from next
                       to (min end (+ next chunk))
                       next to))
               (let ((local-failures '())
                     (local-subnormal 0))
                 (loop for bits from from below to
                       for x = (sb-kernel:make-single-float bits)
                       do (multiple-value-bind (k1 s1) (reference-digits x)
                            (multiple-value-bind (k2 s2) (flonum-to-digits x)
                              (unless (and (= k1 k2) (string= s1 s2))
                                (if (< bits #x00800000)
                                    (incf local-subnormal)
                                    (push (list x k1 s1 k2 s2) local-failures))))))
                 (sb-thread:with-mutex (lock)
                   (incf checked (- to from))
                   (incf subnormal-differences local-subnormal)
                   (dolist (f (nreverse local-failures))
                     (when (< (incf failures) 50)
                       (apply #'format t "FAIL ~S: original ~D ~S, zmij ~D ~S~%" f)))
                   (when (>= to next-report)
                     (setq next-report (+ next-report report-every))
                     (format t "  ~5,1F%  ~:D checked, ~D failure~:P, ~,0F s~%"
                             (* 100 (/ (- to start) (- end start)))
                             checked failures
                             (/ (- (get-internal-real-time) start-time)
                                internal-time-units-per-second))
                     (finish-output))))))))
    (mapc #'sb-thread:join-thread
          (loop repeat n-threads collect (sb-thread:make-thread #'worker))))
  (format t "~:D checked; ~:D subnormal difference~:P (expected)~%"
          checked subnormal-differences)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp failures) failures)
  (sb-ext:exit :code (if (plusp failures) 1 0)))
