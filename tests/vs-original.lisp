;;;; Compares shortest float digits (FLONUM-TO-DIGITS without a position)
;;;; with SBCL's original Burger-Dybvig printer, loaded from the SBCL
;;;; source with its zmij shortcut removed. Normal floats must match
;;;; exactly, ties included. Subnormals are counted separately: there the
;;;; original prints more digits than needed, and zmij prints the shortest.
;;;;
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/vs-original.lisp <count>

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
  (eval
   `(defun reference-flonum-to-digits ,(third form)
      (block %flonum-to-digits ,@(cdddr form)))))

(defun reference-digits (x)
  (let ((s (make-string-output-stream)))
    (reference-flonum-to-digits
     (lambda (d) (write-char (digit-char d) s))
     (lambda (k) k)
     (lambda (k) (values k (get-output-stream-string s)))
     x)))

(defun subnormalp (x)
  (< (abs x)
     (etypecase x
       (single-float least-positive-normalized-single-float)
       (double-float least-positive-normalized-double-float))))

(defvar *failures* 0)
(defvar *checked* 0)
(defvar *subnormal-differences* 0)

(defun test (x)
  (unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x) (zerop x))
    (let ((x (abs x)))
      (incf *checked*)
      (multiple-value-bind (k1 s1) (reference-digits x)
        (multiple-value-bind (k2 s2) (flonum-to-digits x)
          (unless (and (= k1 k2) (string= s1 s2))
            (if (subnormalp x)
                (incf *subnormal-differences*)
                (cl-user::fail (*failures*)
                  "FAIL ~S: original ~D ~S, zmij ~D ~S~%" x k1 s1 k2 s2))))))))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 1000000))
      (state (sb-ext:seed-random-state 13)))
  ;; Every power of two (zmij's irregular path) and its neighbours.
  (loop for e from 1 below 2047
        do (dolist (lo '(0 1)) (dolist (hi '(0 #xFFFFF))
             (test (sb-kernel:make-double-float (logior (ash e 20) hi)
                                                (if (= hi 0) lo #xFFFFFFFF))))))
  (loop for e from 1 below 255
        do (dolist (f '(0 1 #x7FFFFF))
             (test (sb-kernel:make-single-float (logior (ash e 23) f)))))
  ;; Exact ties: values ending in .5, .25, .125, .625 at many scales.
  (loop for n from 1 to 200000
        do (test (+ n 0.5d0)) (test (+ n 0.5f0)) (test (/ n 8d0)) (test (/ n 8f0))
           (test (* n 1024.5d0)) (test (+ (* n 1d6) 0.625d0)))
  (loop for e from 0 to 60
        do (loop for n from 1 to 2000
                 do (test (+ (expt 2d0 e) (/ n 4d0)))
                    (test (+ (expt 2f0 (min e 30)) (/ n 4f0)))))
  ;; Random bit patterns.
  (dotimes (i count)
    (test (sb-kernel:make-double-float (random (ash 1 31) state)
                                       (random (ash 1 32) state)))
    (test (sb-kernel:make-single-float (random (ash 1 31) state))))
  (format t "~:D checked; ~:D subnormal difference~:P (expected)~%"
          *checked* *subnormal-differences*)
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
