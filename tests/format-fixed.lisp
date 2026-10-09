;;;; End-to-end check of fixed-precision FORMAT output: every directive is
;;;; formatted with the fast path, then again with it disabled (so the
;;;; original Burger-Dybvig code runs), and the strings must be identical.
;;;; Inputs include bignums, ratios, huge and tiny floats.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/format-fixed.lisp [count]

(in-package "SB-IMPL")

(defparameter *directives*
  '("~F" "~,2F" "~,0F" "~8,3F" "~,5F" "~,1F" "~12,6F" "~3,1F" "~,2,1F" "~,3,-2F"
    "~,20F" "~E" "~,3E" "~10,2E" "~,2,2E" "~,4,,2E" "~G" "~,2G" "~12,3G"
    "~$" "~10,4$" "~,3$" "~,,,'*8,2F"
    ;; Width but no digit count: relative positions.
    "~12F" "~8F" "~5F" "~3F" "~2F" "~20F" "~12,,2F" "~12,,-2F" "~6,,,'*F" "~@10F"))

(defun format-all (x)
  (loop for d in *directives*
        collect (handler-case (format nil d x)
                  (error (e) (list :error (type-of e))))))

(let* ((count (if (second sb-ext:*posix-argv*)
                  (parse-integer (second sb-ext:*posix-argv*))
                  20000))
       (state (sb-ext:seed-random-state 9))
       (inputs
         (append
          (list (expt 2 100) (expt 10 50) (- (expt 3 40)) (/ 1 3) (/ 22 7)
                (/ (expt 10 30) 7) 0 0.0 -0d0 1d300 -1.7976931348623157d308
                3.4e38 1d-300 least-positive-double-float 5d-324 1d22 1d23
                0.005d0 0.015d0 0.125d0 2.5d0 9.995d0 0.1d0 0.1 123.456d0
                -0.0049d0 0.05 99.995 1d7 12345678.9d0)
          (loop for n from 1 to 2000
                collect (/ n 8d0) collect (* n 0.005d0) collect (/ n 100f0))
          (loop repeat count
                collect (* (if (zerop (random 2 state)) 1 -1)
                           (expt 10d0 (- (random 16d0 state) 6)))
                collect (coerce (expt 10d0 (- (random 12d0 state) 4)) 'single-float)
                collect (sb-kernel:make-double-float
                         (- (random (ash 1 32) state) (ash 1 31))
                         (random (ash 1 32) state)))))
       (inputs (remove-if (lambda (x) (and (floatp x)
                                           (or (sb-ext:float-infinity-p x)
                                               (sb-ext:float-nan-p x))))
                          inputs))
       (fast (mapcar #'format-all inputs))
       ;; Every fixed-precision fast path goes through FLONUM-POSITION-DECIMAL;
       ;; replacing it with (CONSTANTLY NIL) gives the original behaviour.
       (original (fdefinition 'flonum-position-decimal))
       (failures 0))
  (setf (fdefinition 'flonum-position-decimal) (constantly nil))
  (unwind-protect
       (loop for x in inputs
             for new in fast
             for old = (format-all x)
             do (loop for d in *directives*
                      for a in new
                      for b in old
                      unless (equal a b)
                        do (when (< (incf failures) 30)
                             (format t "FAIL ~S ~S: fast ~S, original ~S~%" d x a b))))
    (setf (fdefinition 'flonum-position-decimal) original))
  (format t "~:D inputs x ~D directives~%" (length inputs) (length *directives*))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp failures) failures)
  (sb-ext:exit :code (if (plusp failures) 1 0)))
