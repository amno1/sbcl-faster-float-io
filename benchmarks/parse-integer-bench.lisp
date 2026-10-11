;;;; Would PARSE-INTEGER gain from two changes tried on SB-EXT:PARSE-FLOAT?
;;;; The first made PARSE-FLOAT faster (patch r7); the second did not.
;;;;
;;;; 1. STRING-DISPATCH: WITH-ARRAY-DATA leaves a SIMPLE-STRING, which may
;;;;    be a base string or a character string, so CHAR tests the type
;;;;    before every load. Compiling the body once per kind tests it once.
;;;; 2. ASCII first: DIGIT-CHAR-P on a full CHARACTER also recognizes other
;;;;    scripts' digits. The weight of an ASCII digit or letter is computed
;;;;    from its code, and DIGIT-CHAR-P is called only above code 127, so
;;;;    those digits are still accepted.
;;;;
;;;; OLD is SBCL's PARSE-INTEGER, read from the source tree of the SBCL
;;;; running this file (src/code/reader.lisp). DISPATCH is the same template
;;;; with change 1 only, keeping SBCL's inline DIGIT-CHAR-P; ASCII has both
;;;; changes. All are compiled here, the same way, so that only the changes
;;;; differ, and timed alternately in one process.
;;;; Each comes in the three copies SBCL has: the general function, and
;;;; PARSE-INTEGER10 and PARSE-INTEGER16, which compiled calls with a
;;;; constant radix of 10 (or none) or 16 use. Before timing, all versions
;;;; must agree (values, index, or kind of error) on edge cases and on
;;;; every timed string.
;;;;
;;;;   ~/repos/sbcl-parse-float/run-sbcl.sh --script benchmarks/parse-integer-bench.lisp

(in-package "SB-IMPL")

(defparameter *runs*
  (or (ignore-errors (parse-integer (sb-ext:posix-getenv "RUNS"))) 9))

;;; As in reader.lisp, where it exists only inline.
(declaim (inline whitespace[1]p))
(defun whitespace[1]p (char)
  (case (char-code char)
    ((9 10 32 12 13) t)))

;;; TEXT with PARSE-INTEGER renamed to PREFIX-PARSE-INTEGER where it names
;;; the functions or their block: "'parse-integer" and "(defun parse-integer".
(defun prefix-parse-integer-names (text prefix)
  (flet ((replace-all (old new text)
           (with-output-to-string (out)
             (loop with start = 0
                   for i = (search old text :start2 start)
                   do (write-string text out :start start :end (or i (length text)))
                      (if i
                          (progn (write-string new out) (setq start (+ i (length old))))
                          (return))))))
    (replace-all "(defun parse-integer" (format nil "(defun ~Aparse-integer" prefix)
                 (replace-all "'parse-integer" (format nil "'~Aparse-integer" prefix) text))))

;;; OLD: SBCL's own PARSE-INTEGER, as OLD-PARSE-INTEGER, OLD-PARSE-INTEGER10
;;; and OLD-PARSE-INTEGER16. The names are changed in the text: the block
;;; name is computed with SYMBOLICATE inside a backquote, and SBCL reads a
;;; backquote's commas as structures, which SUBST does not look into.
(let* ((path (merge-pathnames "../../src/code/reader.lisp"
                              (make-pathname :name nil :type nil
                                             :defaults sb-ext:*runtime-pathname*)))
       (text (with-open-file (s path)
               (let ((string (make-string (file-length s))))
                 (subseq string 0 (read-sequence string s)))))
       (start (search "(macrolet ((def (radix)" text
                      :start2 (search ";;;; PARSE-INTEGER" text)))
       (form (let ((*package* (find-package "SB-IMPL")))
               (read-from-string (prefix-parse-integer-names (subseq text start) "old-") t nil))))
  (eval form))

;;; The same template with the changes: STRING-DISPATCH, and with ASCII
;;; true the weight of ASCII digits and letters from their code. PREFIX
;;; names the three functions, as PREFIX-PARSE-INTEGER-NAMES does.
(macrolet ((def (prefix radix ascii)
             `(flet ((parse-error (format-control)
                       (error 'simple-parse-error
                              :format-control format-control
                              :format-arguments (list string))))
                (with-array-data ((string string :offset-var offset)
                                  (start start)
                                  (end end)
                                  :check-fill-pointer t)
                  (let ((radix ,(or radix 'radix))
                        (index (do ((i start (1+ i)))
                                   ((>= i end)
                                    (if junk-allowed
                                        (return-from ,(symbolicate prefix 'parse-integer
                                                                   (if radix (princ-to-string radix) ""))
                                          (values nil end))
                                        (parse-error "no non-whitespace characters in string ~S.")))
                                 (declare (fixnum i))
                                 (unless (whitespace[1]p (char string i)) (return i))))
                        (minusp nil)
                        (found-digit nil))
                    (declare (fixnum index))
                    (string-dispatch ((simple-array character (*)) simple-base-string) string
                      (flet ((weight (char)
                               ,(if ascii
                                    ;; ASCII digits and letters from their
                                    ;; code; others through DIGIT-CHAR-P.
                                    '(let* ((code (char-code char))
                                            (w (cond ((<= 48 code 57) (- code 48))
                                                     ((<= 65 code 90) (- code 55))
                                                     ((<= 97 code 122) (- code 87)))))
                                      (cond (w (and (< w radix) w))
                                            ((< code 128) nil)
                                            (t (digit-char-p char radix))))
                                    '(digit-char-p char radix))))
                        (declare (inline weight digit-char-p))
                        (let ((char (char string index)))
                          (when (or (eql char #\+) (eql char #\-))
                            (setq minusp (char= char #\-))
                            (incf index)))
                        (let ((final-result 0))
                          (macrolet ((compute (type)
                                       `(let ((result 0))
                                          (declare (type ,type result))
                                          (loop
                                           (when (>= index end) (return nil))
                                           (let* ((char (char string index))
                                                  (weight (weight char)))
                                             (cond (weight
                                                    (setq result (truly-the ,type
                                                                            (+ weight
                                                                               (truly-the ,type (* result radix))))
                                                          found-digit t))
                                                   (junk-allowed (return nil))
                                                   ((whitespace[1]p char)
                                                    (loop
                                                     (incf index)
                                                     (when (>= index end) (return))
                                                     (unless (whitespace[1]p (char string index))
                                                       (parse-error "junk in string ~S")))
                                                    (return nil))
                                                   (t
                                                    (parse-error "junk in string ~S"))))
                                           (incf index))
                                          (setf final-result
                                                (if minusp
                                                    (- result)
                                                    result)))))
                            ,(if radix
                                 (let ((max-length
                                         (loop for i from 1
                                               for mi = (1- radix) then (+ (* mi radix) (1- radix))
                                               when (> mi most-positive-word) do (return (1- i)))))
                                   `(if (<= (- end index) ,max-length)
                                        (compute word)
                                        (compute t)))
                                 `(compute t)))
                          (values
                           (if found-digit
                               final-result
                               (if junk-allowed
                                   nil
                                   (parse-error "no digits in string ~S")))
                           (- index offset))))))))))
  (defun dispatch-parse-integer (string &key (start 0) end (radix 10) junk-allowed)
    (def "DISPATCH-" nil nil))
  (defun dispatch-parse-integer10 (string start end junk-allowed)
    (def "DISPATCH-" 10 nil))
  (defun dispatch-parse-integer16 (string start end junk-allowed)
    (def "DISPATCH-" 16 nil))
  (defun ascii-parse-integer (string &key (start 0) end (radix 10) junk-allowed)
    (def "ASCII-" nil t))
  (defun ascii-parse-integer10 (string start end junk-allowed)
    (def "ASCII-" 10 t))
  (defun ascii-parse-integer16 (string start end junk-allowed)
    (def "ASCII-" 16 t)))

;;; The ways each version is called: (NAME OLD DISPATCH ASCII), each a
;;; function of (STRING START END JUNK-ALLOWED).
(defmacro general (name radix)
  `(lambda (s start end junk)
     (,name s :start start :end end :radix ,radix :junk-allowed junk)))

(defparameter *entries*
  (list (list "parse-integer10"
              #'old-parse-integer10 #'dispatch-parse-integer10 #'ascii-parse-integer10)
        (list "parse-integer16"
              #'old-parse-integer16 #'dispatch-parse-integer16 #'ascii-parse-integer16)
        (list "parse-integer :radix 10" (general old-parse-integer 10)
              (general dispatch-parse-integer 10) (general ascii-parse-integer 10))
        (list "parse-integer :radix 36" (general old-parse-integer 36)
              (general dispatch-parse-integer 36) (general ascii-parse-integer 36))))

(defvar *failures* 0)

(defun outcome (f string junk)
  (handler-case (multiple-value-list (funcall f string 0 nil junk))
    (error (c) (list :error (type-of c)))))

;;; All versions must agree on STRING, as a character string and, if it
;;; is ASCII, as a base string, with and without :JUNK-ALLOWED.
(defun check (entry string)
  (destructuring-bind (name old &rest new) entry
    (dolist (s (if (every (lambda (c) (< (char-code c) 128)) string)
                   (list (coerce string '(simple-array character (*)))
                         (coerce string 'simple-base-string))
                   (list (coerce string '(simple-array character (*))))))
      (dolist (junk '(nil t))
        (let ((expected (outcome old s junk)))
          (dolist (f new)
            (let ((got (outcome f s junk)))
              (unless (equal got expected)
                (when (<= (incf *failures*) 20)
                  (format t "FAIL ~A ~S junk ~A: old ~S, new ~S~%"
                          name s junk expected got))))))))))

(defparameter *edge-cases*
  (list "0" "-0" "+7" "-12" "  42  " "12 " " 12" "1 2" "12x" "x12" "" "   " "-" "+"
        "- 12" "007" "123456789012345678901234567890" "-99999999999999999999"
        "ff" "FF" "fF" "zz" "ZZ" "10g" "1f" "a" "A" "/" ":" "@" "[" "`" "{"
        (format nil "~C12~C" #\Tab #\Newline)
        (coerce (list (code-char #x661) (code-char #x662)) 'string)    ; Arabic-Indic 12
        (coerce (list #\1 (code-char #xFF10) #\2) 'string)            ; fullwidth 0
        (coerce (list #\1 (code-char #x131)) 'string)))               ; dotless i

;;; ns per call of F on every string of V.
(defun ns-per-call (f v)
  (declare (function f) (simple-vector v))
  (sb-ext:gc)
  (let ((t0 (get-internal-real-time)))
    (loop repeat 5 do (loop for s across v do (funcall f s 0 nil nil)))
    (/ (* 1d9 (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
       (* 5 (length v)))))

;;; COUNT random strings of FROM to TO digits in RADIX, of KIND.
(defun strings (state from to radix kind count)
  (coerce (loop repeat count
                collect (let ((s (make-string (+ from (random (1+ (- to from)) state)))))
                          (dotimes (i (length s))
                            (setf (char s i) (char-downcase (digit-char (random radix state) radix))))
                          (coerce s (if (eq kind :base)
                                        'simple-base-string
                                        '(simple-array character (*))))))
          'simple-vector))

;;; The timed cases: entry, digits from, to.
(defparameter *cases*
  '((0 1 5) (0 9 9) (0 18 18) (0 30 30) (1 8 8) (1 16 16) (2 1 5) (2 18 18) (3 8 8)))

(let ((state (sb-ext:seed-random-state 31)))
  (format t "~A~%ns per call, best of ~D; all versions compiled the same way, alternating~%~%"
          (lisp-implementation-version) *runs*)
  (dolist (entry *entries*)
    (dolist (s *edge-cases*) (check entry s)))
  (format t "~38A ~10A ~6@A ~9@A ~6@A~%" "" "string" "old" "dispatch" "ascii")
  (loop for (n from to) in *cases*
        for entry = (nth n *entries*)
        for radix = (case n (1 16) (3 36) (t 10))
        do (dolist (kind '(:character :base))
             (let ((v (strings state from to radix kind 200000))
                   (best (list 1d10 1d10 1d10)))
               (loop for s across v do (check entry s))
               (loop repeat *runs*
                     do (setq best (mapcar (lambda (f b) (min b (ns-per-call f v)))
                                           (rest entry) best)))
               (format t "~38A ~10A ~{~6,1F ~9,1F ~6,1F~}~%"
                       (format nil "~A, ~:[~D-~D~;~D~*~] digits" (first entry) (= from to) from to)
                       (string-downcase kind) best)
               (finish-output))))
  (format t "~%~:[OK~;FAILED~]: ~D difference~:P from OLD~%" (plusp *failures*) *failures*)
  (sb-ext:exit :code (if (plusp *failures*) 1 0)))
