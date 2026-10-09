;;;; Helpers shared by several tests. A test loads this right after its
;;;; IN-PACKAGE form, before any code that uses them:
;;;;
;;;;   (load (merge-pathnames "common.lisp" *load-truename*))

(in-package "CL-USER")

;;; Count a failure in the place COUNTER and print it, with FORMAT's
;;; CONTROL and ARGS, unless LIMIT failures have been printed already.
;;; The output is flushed, so failures show at once in long runs.
(defmacro fail ((counter &optional (limit 50)) control &rest args)
  `(when (<= (incf ,counter) ,limit)
     (format t ,control ,@args)
     (finish-output)))

;;; Call FUNCTION with every combination of one value from each list in
;;; VALUE-LISTS, as a list of arguments, the first list varying slowest.
(defun map-combinations (function value-lists)
  (labels ((walk (lists chosen)
             (if (endp lists)
                 (funcall function chosen)
                 (dolist (value (first lists))
                   (walk (rest lists) (append chosen (list value)))))))
    (walk value-lists '())))

;;; The text of FILE, a path such as "src/code/print.lisp", as it was in the
;;; original SBCL: commit ORIGINAL_REV (default c7621755f, from before any
;;; zmij work), read with git from the source tree of the SBCL running the
;;; test.
(defun original-source (file)
  (let* ((tree (namestring
                (merge-pathnames "../../" (make-pathname
                                           :name nil :type nil
                                           :defaults sb-ext:*runtime-pathname*))))
         (rev (or (sb-ext:posix-getenv "ORIGINAL_REV") "c7621755f"))
         (output (make-string-output-stream))
         (process (sb-ext:run-program "git"
                                      (list "-C" tree "show"
                                            (format nil "~A:~A" rev file))
                                      :search t :output output :error nil)))
    (unless (zerop (sb-ext:process-exit-code process))
      (error "git show ~A:~A failed in ~A" rev file tree))
    (get-output-stream-string output)))
