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

(let* ((args (rest sb-ext:*posix-argv*))
       (start (if (first args) (parse-integer (first args) :radix 16) 1))
       (end (if (second args) (parse-integer (second args) :radix 16) #x7F800000))
       (n-threads (or (ignore-errors (parse-integer (sb-ext:posix-getenv "THREADS"))) 8))
       (n-doubles (or (ignore-errors (parse-integer (sb-ext:posix-getenv "DOUBLES"))) 0))
       (lock (sb-thread:make-mutex :name "single-roundtrip"))
       (failures 0)
       (checked 0)
       (next start)
       (chunk (expt 2 20))
       (report-every (max 1 (floor (- end start) 64)))
       (next-report (+ start report-every))
       (start-time (get-internal-real-time)))
  (labels ((report-failure (control &rest args)
             (sb-thread:with-mutex (lock)
               (when (< (incf failures) 50)
                 (apply #'format t control args)
                 (finish-output))))
           (check (x)
             ;; X printed and read back must be X, through the reader and
             ;; through PARSE-FLOAT.
             (let* ((string (prin1-to-string x))
                    (read (handler-case (read-from-string string)
                            (error (c) c)))
                    (parsed (handler-case (sb-ext:parse-float string)
                              (error (c) c))))
               (unless (eql read x)
                 (report-failure "FAIL read ~S: ~S gave ~S~%" x string read))
               (unless (eql parsed x)
                 (report-failure "FAIL parse-float ~S: ~S gave ~S~%" x string parsed))))
           (single-worker ()
             (let ((*read-default-float-format* 'single-float))
               (loop
                 (let (from to)
                   (sb-thread:with-mutex (lock)
                     (when (>= next end) (return))
                     (setq from next
                           to (min end (+ next chunk))
                           next to))
                   (loop for bits from from below to
                         do (check (sb-kernel:make-single-float bits)))
                   (sb-thread:with-mutex (lock)
                     (incf checked (- to from))
                     (when (>= to next-report)
                       (setq next-report (+ next-report report-every))
                       (format t "  ~5,1F%  ~:D singles, ~D failure~:P, ~,0F s~%"
                               (* 100 (/ (- to start) (- end start)))
                               checked failures
                               (/ (- (get-internal-real-time) start-time)
                                  internal-time-units-per-second))
                       (finish-output)))))))
           (double-worker (count seed)
             ;; Random finite doubles, of both signs, including subnormals.
             (let ((*read-default-float-format* 'double-float)
                   (state (sb-ext:seed-random-state seed)))
               (loop repeat count
                     do (loop for high = (- (random (ash 1 32) state) (ash 1 31))
                              unless (= (ldb (byte 11 20) high) #x7FF)
                                do (check (sb-kernel:make-double-float
                                           high (random (ash 1 32) state)))
                                   (return))))))
    (format t "Round trip of singles #x~8,'0X below #x~8,'0X on ~D threads~%"
            start end n-threads)
    (finish-output)
    (mapc #'sb-thread:join-thread
          (loop repeat n-threads
                collect (sb-thread:make-thread #'single-worker)))
    (when (plusp n-doubles)
      (format t "~:D random doubles on ~D threads~%" n-doubles n-threads)
      (finish-output)
      (mapc #'sb-thread:join-thread
            (loop for i below n-threads
                  collect (let ((i i))
                            (sb-thread:make-thread
                             (lambda ()
                               (double-worker (ceiling n-doubles n-threads) (+ 1000 i))))))))
    (format t "~:D singles~@[ and ~:D doubles~] checked~%" checked
            (and (plusp n-doubles) n-doubles))
    (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp failures) failures)
    (sb-ext:exit :code (if (plusp failures) 1 0))))
