;;;; Checks the portable %ZMIJ-STORE-DIGITS against the built-in one
;;;; (the SSE2 VOP on x86-64), on random and edge-case inputs.
;;;;   ~/repos/sbcl-zmij/run-sbcl.sh --script tests/fallback.lisp [count]

(in-package "SB-IMPL")

(load (merge-pathnames "common.lisp" *load-truename*))

;;; Load the portable definitions from the SBCL source, so this always
;;; tests the code that other platforms will run. ZMIJ-BCD8 is tree-shaken
;;; out of x86-64 builds, so it is loaded too. The portable
;;; %ZMIJ-STORE-DIGITS is defined as PORTABLE-STORE-DIGITS.
;;; src/code/zmij.lisp of the SBCL running this test.
(defparameter *zmij-source*
  (namestring (merge-pathnames "../../src/code/zmij.lisp"
                               (make-pathname :name nil :type nil :defaults sb-ext:*runtime-pathname*))))

(defun source-form (text head)
  (let ((start (search head text)))
    (unless start (error "~S not found in ~A" head *zmij-source*))
    (let ((*package* (find-package "SB-IMPL")))
      (read-from-string text t nil :start start))))

(let ((text (with-open-file (s *zmij-source*)
              (let ((string (make-string (file-length s))))
                (subseq string 0 (read-sequence string s))))))
  (eval (source-form text "(defun zmij-bcd8"))
  (let ((form (source-form text "(defun %zmij-store-digits")))
    (eval `(defun portable-store-digits ,@(cddr form)))))

(defun builtin-store-digits (string index hi lo)
  (declare (type simple-base-string string) (type index index)
           (type (unsigned-byte 32) hi lo))
  (%zmij-store-digits string index hi lo))

(defvar *failures* 0)

;;; Store the 16 digits of HI and LO (two 8-digit groups) at INDEX with both
;;; versions. The nonzero-digit masks they return and the strings they write
;;; must be equal, and the digits must be HI and LO in decimal.
(defun check (hi lo index)
  (let ((a (make-string 20 :element-type 'base-char :initial-element #\x))
        (b (make-string 20 :element-type 'base-char :initial-element #\x)))
    (let ((mask-a (portable-store-digits a index hi lo))
          (mask-b (builtin-store-digits b index hi lo))
          (expected (format nil "~8,'0D~8,'0D" hi lo)))
      (unless (and (= mask-a mask-b)
                   (string= a b)
                   (string= a expected :start1 index :end1 (+ index 16)))
        (cl-user::fail (*failures*)
          "FAIL ~D ~D at ~D: ~S ~X vs ~S ~X~%" hi lo index a mask-a b mask-b)))))

;;; Edge cases: every combination of these HI, LO and INDEX values.
(defparameter *edge-values*
  '((0 1 9 10 99999999 12345678 10000000)
    (0 1 9 10 99999999 87654321 10000000)
    (0 1 2 3 4)))

(let ((count (if (second sb-ext:*posix-argv*)
                 (parse-integer (second sb-ext:*posix-argv*))
                 2000000))
      (state (sb-ext:seed-random-state 7)))
  (cl-user::map-combinations (lambda (args) (apply #'check args)) *edge-values*)
  (loop repeat count
        do (check (random 100000000 state) (random 100000000 state)
                  (random 5 state)))
  (format t "~:[OK~;FAILED~]: ~D failure~:P~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
