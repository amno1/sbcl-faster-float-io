;;;; What the patch series change, from git: the definitions each series
;;;; adds, changes or removes, file by file, and its size in lines.
;;;;
;;;; Each series is compared with the branch it is built on, as the patches
;;;; are: printing and reading with upstream master, the integer series
;;;; with the series below them. A definition is a form that starts with
;;;; DEF..., DEFINE-... or DECLAIM at most two columns in (so also those in
;;;; a top-level PROGN or MACROLET), cut at its closing parenthesis.
;;;; Definitions with the same name, such as the DEFTRANSFORMs of FORMAT,
;;;; are paired by content. "SLOC" counts added lines that are neither
;;;; blank nor comments. Finally, the combined branch must have each
;;;; series' version of every file the series change.
;;;;
;;;;   sbcl --script patch-stats.lisp [path-to-sbcl-repository]

(defparameter *repository*
  (or (second sb-ext:*posix-argv*)
      (namestring (merge-pathnames "repos/sbcl/" (user-homedir-pathname)))))

;;; (name base branch) for each series.
(defparameter *series*
  '(("p1-p13: printing and FORMAT" "official/master" "sbcl-zmij")
    ("r1-r7: reading and SB-EXT:PARSE-FLOAT" "official/master" "sbcl-parse-float")
    ("i1-i2: integer printing" "sbcl-zmij" "sbcl-int-print")
    ("n1-n2: READ-TOKEN fast path" "sbcl-parse-float" "sbcl-read-fast")))

(defparameter *combined-branch* "sb-simd-512")

;;;; Git

(defun git (&rest args)
  "The output of git ARGS in *REPOSITORY*, or NIL if git fails."
  (let* ((output (make-string-output-stream))
         (process (sb-ext:run-program "git" (list* "-C" *repository* args)
                                      :search t :output output :error nil)))
    (when (zerop (sb-ext:process-exit-code process))
      (get-output-stream-string output))))

(defun lines (string)
  (with-input-from-string (s (or string ""))
    (loop for line = (read-line s nil) while line collect line)))

(defun file-at (revision path)
  "The text of PATH at REVISION, or NIL if it does not exist there."
  (git "show" (format nil "~A:~A" revision path)))

(defun changed-files (base branch)
  (lines (git "diff" "--name-only" (format nil "~A..~A" base branch))))

;;;; Definitions in a Lisp file

(defun form-end (text start)
  "The index after the form that starts with the parenthesis at START.
Strings, comments and character literals are skipped."
  (let ((depth 0) (i start) (n (length text)))
    (loop while (< i n)
          do (let ((c (char text i)))
               (cond ((char= c #\;)
                      (setq i (or (position #\Newline text :start i) n)))
                     ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
                      (setq i (+ 2 (or (search "|#" text :start2 (+ i 2)) (- n 2)))))
                     ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
                      (incf i 3))
                     ((char= c #\")
                      (incf i)
                      (loop while (and (< i n) (char/= (char text i) #\"))
                            do (incf i (if (char= (char text i) #\\) 2 1)))
                      (incf i))
                     ((char= c #\()
                      (incf depth) (incf i))
                     ((char= c #\))
                      (incf i)
                      (when (zerop (decf depth)) (return-from form-end i)))
                     (t (incf i)))))
    n))

(defun definition-head-p (word)
  (let ((word (string-downcase word)))
    (or (and (> (length word) 3) (string= "def" word :end2 3))
        (string= "def" word)
        (and (> (length word) 7) (string= "define-" word :end2 7))
        (string= "declaim" word))))

(defun words-after (text start count)
  "The first COUNT words of TEXT after START, without parentheses."
  (let ((words '()) (i start))
    (loop repeat count
          do (let* ((s (position-if-not (lambda (c) (member c '(#\Space #\( #\Tab))) text :start i))
                    (e (and s (position-if (lambda (c) (member c '(#\Space #\( #\) #\Newline #\Tab))) text :start s))))
               (unless (and s e) (return))
               (push (subseq text s e) words)
               (setq i e)))
    (nreverse words)))

;;; A DECLAIM is named by its whole first line, which names what it
;;; declares; anything else by its first two words.
(defun definition-name (text start words)
  (if (string-equal (first words) "declaim")
      (string-trim " " (subseq text start (or (position #\Newline text :start start)
                                              (length text))))
      (format nil "~{~A~^ ~}" words)))

(defun definitions (text)
  "A list of (name . text) for the definitions in TEXT, in order."
  (let ((result '()) (covered 0) (line-start 0) (n (length text)))
    (loop while (< line-start n)
          do (let* ((indent (or (position #\Space text :start line-start :test-not #'char=) n))
                    (next (1+ (or (position #\Newline text :start line-start) (1- n)))))
               (when (and (>= indent covered)
                          (<= (- indent line-start) 2)
                          (< indent n)
                          (char= (char text indent) #\())
                 (let ((words (words-after text (1+ indent) 2)))
                   (when (and words (definition-head-p (first words)))
                     (let ((end (form-end text indent)))
                       (push (cons (definition-name text indent words) (subseq text indent end))
                             result)
                       (setq covered end)))))
               (setq line-start next)))
    (nreverse result)))

(defun line-difference (a b)
  "Lines of A missing from B plus lines of B missing from A, as multisets."
  (flet ((missing (x y)
           (let ((remaining (copy-list (lines y))))
             (loop for line in (lines x)
                   for found = (member line remaining :test #'string=)
                   if found do (setf remaining (remove line remaining :count 1 :test #'string=))
                   else count t))))
    (+ (missing a b) (missing b a))))

(defun compare-definitions (old new)
  "Lists of (name), (name lines) and (name) for the definitions only in
NEW, changed, and only in OLD. Same-named ones are paired by content."
  (let ((added '()) (changed '()) (removed '())
        (names (remove-duplicates (mapcar #'car (append old new)) :test #'string= :from-end t)))
    (dolist (name names)
      (let ((olds (loop for (n . text) in old when (string= n name) collect text))
            (news (loop for (n . text) in new when (string= n name) collect text)))
        ;; Identical texts are unchanged.
        (dolist (text (copy-list news))
          (when (member text olds :test #'string=)
            (setq olds (remove text olds :count 1 :test #'string=)
                  news (remove text news :count 1 :test #'string=))))
        (loop for o in olds for n in news
              do (push (list name (line-difference o n)) changed))
        (loop repeat (- (length news) (length olds)) do (push name added))
        (loop repeat (- (length olds) (length news)) do (push name removed))))
    (values (nreverse added) (nreverse changed) (nreverse removed))))

;;;; Reports

(defun report-definitions (base branch)
  (dolist (file (changed-files base branch))
    (let ((old (file-at base file)) (new (file-at branch file)))
      (format t "  ~A~:[~;  (new file)~]~:[~;  (deleted)~]~%" file (null old) (null new))
      (when (and new (search ".lisp" file :from-end t))
        (multiple-value-bind (added changed removed)
            (compare-definitions (definitions (or old "")) (definitions new))
          (dolist (name added) (format t "      added    ~A~%" name))
          (loop for (name count) in changed
                do (format t "      changed  ~A  (~D line~:P)~%" name count))
          (dolist (name removed) (format t "      removed  ~A~%" name)))))))

(defun file-kind (path)
  (cond ((eql 0 (search "tests/" path)) :tests)
        ((eql 0 (search "src/" path)) :code)
        (t :other)))

(defun comment-line-p (line)
  (let ((s (string-left-trim '(#\Space #\Tab) line)))
    (and (plusp (length s)) (char= (char s 0) #\;))))

(defun size (base branch)
  "A list of (kind added sloc comments removed) for code, tests and other."
  (let ((totals (list (list :code 0 0 0 0) (list :tests 0 0 0 0) (list :other 0 0 0 0)))
        (kind nil))
    (dolist (line (lines (git "diff" "-U0" (format nil "~A..~A" base branch))) totals)
      (cond ((eql 0 (search "+++ " line))
             (setq kind (and (eql 0 (search "+++ b/" line)) (file-kind (subseq line 6)))))
            ((eql 0 (search "--- " line)))
            ((null kind))
            ((and (plusp (length line)) (char= (char line 0) #\+))
             (let ((entry (assoc kind totals)) (text (subseq line 1)))
               (incf (second entry))
               (cond ((comment-line-p text) (incf (fourth entry)))
                     ((plusp (length (string-trim '(#\Space #\Tab) text))) (incf (third entry))))))
            ((and (plusp (length line)) (char= (char line 0) #\-))
             (incf (fifth (assoc kind totals))))))))

(defun report-sizes ()
  (format t "~&~%Size: lines added, SLOC (added, not blank or comment), comment lines,~
             ~%lines removed~%~%~40A ~6A ~6@A ~6@A ~8@A ~7@A~%"
          "series" "part" "added" "SLOC" "comments" "removed")
  (let ((sum (list (list :code 0 0 0 0) (list :tests 0 0 0 0) (list :other 0 0 0 0))))
    (loop for (name base branch) in *series*
          do (loop for (kind . counts) in (size base branch)
                   unless (every #'zerop counts)
                     do (format t "~40A ~6A ~{~6D ~6D ~8D ~7D~}~%"
                                name (string-downcase kind) counts)
                        (setf (cdr (assoc kind sum)) (mapcar #'+ counts (cdr (assoc kind sum))))))
    (loop for (kind . counts) in sum
          do (format t "~40A ~6A ~{~6D ~6D ~8D ~7D~}~%"
                     "total" (string-downcase kind) counts))))

(defun report-combined ()
  "Files whose version in *COMBINED-BRANCH* differs from the last series
that changes them."
  (let ((latest (make-hash-table :test #'equal)))
    (loop for (nil base branch) in *series*
          do (dolist (file (changed-files base branch))
               (setf (gethash file latest) branch)))
    (format t "~&~%~A against the series~%" *combined-branch*)
    (let ((differences 0))
      (maphash (lambda (file branch)
                 (unless (equal (file-at branch file) (file-at *combined-branch* file))
                   (incf differences)
                   (format t "  differs from ~A: ~A~%" branch file)))
               latest)
      (format t "  ~D file~:P checked, ~D differ~:[ (COPYING merges two notices)~;~]~%"
              (hash-table-count latest) differences (zerop differences)))))

(format t "Repository: ~A~%" *repository*)
(loop for (name base branch) in *series*
      do (format t "~%~A  (~A..~A)~%" name base branch)
         (report-definitions base branch))
(report-sizes)
(report-combined)
