;;;; John McCarthy 1927-2011

(in-package :sys.c)

(defparameter *perform-tce* nil
  "When true, attempt to eliminate tail calls.")
(defparameter *suppress-builtins* nil
  "When T, the built-in functions will not be used and full calls will
be generated instead.")
(defparameter *enable-branch-tensioner* t)
(defparameter *trace-asm* nil)

(defvar *run-counter* nil)
(defvar *load-list* nil)
(defvar *r8-value* nil)
(defvar *stack-values* nil)
(defvar *for-value* nil)
(defvar *rename-list* nil)
(defvar *code-accum* nil)
(defvar *trailers* nil)
(defvar *current-lambda-name* nil)

(defconstant +binding-stack-gs-offset+ (- (* 1 8) sys.int::+tag-array-like+))
(defconstant +tls-base-offset+ (- sys.int::+tag-array-like+))
(defconstant +tls-offset-shift+ (+ 8 3))

(defun emit (&rest instructions)
  (dolist (i instructions)
    (push i *code-accum*)))

(defmacro emit-trailer ((&optional name) &body body)
  `(push (let ((*code-accum* '()))
	   ,(when name
		  `(emit ,name))
	   (progn ,@body)
	   (nreverse *code-accum*))
	 *trailers*))

(defun fixnum-to-raw (integer)
  (check-type integer (signed-byte 61))
  (* integer 8))

(defun character-to-raw (character)
  (check-type character character)
  (logior (ash (char-int character) 4) 10))

(defun control-stack-frame-offset (slot)
  "Convert a control stack slot number to an offset."
  (- (* (1+ slot) 8)))

(defun control-stack-slot-ea (slot)
  "Return an effective address for a control stack slot."
  `(:stack ,slot))

;;; TODO: This should work on a stack-like system so that slots can be
;;; reused when the allocation is no longer needed.
(defun allocate-control-stack-slots (count)
  (when (oddp count) (incf count))
  (when (oddp (length *stack-values*))
    (vector-push-extend nil *stack-values*))
  (prog1 (length *stack-values*)
    (dotimes (i count)
      (vector-push-extend '(:unboxed . :home) *stack-values*))))

(defun no-tail (value-mode)
  (ecase value-mode
    ((:multiple :predicate t nil) value-mode)
    (:tail :multiple)))

(defun codegen-lambda (lambda)
  (let* ((*current-lambda* lambda)
         (*current-lambda-name* (or (lambda-information-name lambda)
                                    (list 'lambda :in (or *current-lambda-name*
                                                          (when *compile-file-pathname*
                                                            (princ-to-string *compile-file-pathname*))))))
         (*run-counter* 0)
         (*load-list* '())
         (*r8-value* nil)
         (*stack-values* (make-array 8 :fill-pointer 0 :adjustable t))
         (*for-value* t)
         (*rename-list* '())
         (*code-accum* '())
         (*trailers* '())
         (arg-registers '(:r8 :r9 :r10 :r11 :r12)))
    ;; Check some assertions.
    ;; No keyword arguments, no special arguments, no non-constant
    ;; &optional init-forms and no non-local arguments.
    (assert (not (lambda-information-enable-keys lambda)) ()
            "&KEY arguments did not get lowered!")
    (assert (every (lambda (arg)
                     (lexical-variable-p arg))
                   (lambda-information-required-args lambda)))
    (assert (every (lambda (arg)
                     (and (lexical-variable-p (first arg))
                          (quoted-form-p (second arg))
                          (or (null (third arg))
                              (lexical-variable-p (first arg)))))
                   (lambda-information-optional-args lambda)))
    (assert (or (null (lambda-information-rest-arg lambda))
                (lexical-variable-p (lambda-information-rest-arg lambda))))
    ;; Free up :RBX quickly.
    (let ((env-arg (lambda-information-environment-arg lambda)))
      (when env-arg
        (let ((ofs (find-stack-slot)))
          (setf (aref *stack-values* ofs) (cons env-arg :home))
          (emit `(sys.lap-x86:mov64 (:stack ,ofs) :rbx)))))
    ;; Compile argument setup code.
    (let ((current-arg-index 0))
      (dolist (arg (lambda-information-required-args lambda))
        (incf current-arg-index)
        (let ((ofs (find-stack-slot)))
          (setf (aref *stack-values* ofs) (cons arg :home))
          (if arg-registers
              (emit `(sys.lap-x86:mov64 (:stack ,ofs) ,(pop arg-registers)))
              (emit `(sys.lap-x86:mov64 :r8 (:cfp ,(* (+ (- current-arg-index 6) 2) 8)))
                    `(sys.lap-x86:mov64 (:stack ,ofs) :r8)))))
      (dolist (arg (lambda-information-optional-args lambda))
        (let ((mid-label (gensym))
              (end-label (gensym))
              (var-ofs (find-stack-slot))
              (sup-ofs nil))
          (setf (aref *stack-values* var-ofs) (cons (first arg) :home))
          (when (and (third arg)
                     (not (zerop (lexical-variable-use-count (third arg)))))
            (setf sup-ofs (find-stack-slot))
            (setf (aref *stack-values* sup-ofs) (cons (third arg) :home)))
          ;; Check if this argument was supplied.
          (emit `(sys.lap-x86:cmp64 :rcx ,(fixnum-to-raw current-arg-index))
                `(sys.lap-x86:jle ,mid-label))
          ;; Argument supplied, stash wherever.
          (if arg-registers
              (emit `(sys.lap-x86:mov64 (:stack ,var-ofs) ,(pop arg-registers)))
              (emit `(sys.lap-x86:mov64 :r8 (:cfp ,(* (+ (- current-arg-index 5) 2) 8)))
                    `(sys.lap-x86:mov64 (:stack ,var-ofs) :r8)))
          (when sup-ofs
            (emit `(sys.lap-x86:mov64 (:stack ,sup-ofs) t)))
          (emit `(sys.lap-x86:jmp ,end-label)
                mid-label)
          ;; Argument not supplied. Init-form is a quoted constant.
          (let ((tag (second arg)))
            (load-in-r8 tag t)
            (setf *r8-value* nil)
            (emit `(sys.lap-x86:mov64 (:stack ,var-ofs) :r8))
            (when sup-ofs
              (emit `(sys.lap-x86:mov64 (:stack ,sup-ofs) nil))))
          (emit end-label)
          (incf current-arg-index))))
    ;; Deal with &REST late to avoid excess register spilling.
    (let ((rest-arg (lambda-information-rest-arg lambda)))
      (when (and rest-arg
                 ;; Avoid generating code &REST code when the variable isn't used.
                 (not (zerop (lexical-variable-use-count rest-arg))))
        (emit-rest-list lambda arg-registers)))
    (let* ((code-tag (let ((*for-value* (if *perform-tce* :tail :multiple)))
                       (cg-form `(progn ,@(lambda-information-body lambda))))))
      (when code-tag
        (unless (eql code-tag :multiple)
          (load-in-r8 code-tag t)
          (emit `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))))
        (emit `(sys.lap-x86:leave)
              `(sys.lap-x86:ret))))
    (let* ((final-code (nconc (generate-entry-code lambda)
                              (nreverse *code-accum*)
                              (apply #'nconc *trailers*)))
           (homes (loop for (var . loc) across *stack-values*
                     for i from 0
                     when (and (lexical-variable-p var)
                               (eql loc :home))
                     collect (list (lexical-variable-name var) i))))
      (when *enable-branch-tensioner*
        (setf final-code (tension-branches final-code)))
      (when *trace-asm*
        (format t "~S:~%" *current-lambda-name*)
        (format t "Final values: ~S~%" *stack-values*)
        (format t "~{~S~%~}" final-code))
      (sys.int::assemble-lap
       final-code
       *current-lambda-name*
       (list :debug-info
             *current-lambda-name*
             homes
             (when (lambda-information-environment-layout lambda)
               (position (first (lambda-information-environment-layout lambda))
                         *stack-values*
                         :key #'car))
             (second (lambda-information-environment-layout lambda))
             (when *compile-file-pathname*
               (princ-to-string *compile-file-pathname*))
             sys.int::*top-level-form-number*
             (lambda-information-lambda-list lambda)
             (lambda-information-docstring lambda))))))

(defun generate-entry-code (lambda)
  (let ((entry-label (gensym "ENTRY"))
	(invalid-arguments-label (gensym "BADARGS")))
    (emit-trailer (invalid-arguments-label)
      (emit `(sys.lap-x86:mov64 :r13 (:constant sys.int::%invalid-argument-error))
            `(sys.lap-x86:call (:symbol-function :r13))
            `(sys.lap-x86:ud2)))
    (nconc
     (list entry-label
	   ;; Create control stack frame.
	   `(sys.lap-x86:push :cfp)
	   `(sys.lap-x86:mov64 :cfp :csp))
     (let ((n-slots (length *stack-values*)))
       (when (oddp n-slots) (incf n-slots))
       ;; Adjust stack.
       (list `(sys.lap-x86:sub64 :rsp ,(* n-slots 8))))
     ;; Flush stack slots.
     (loop for value across *stack-values*
        for i from 0
        unless (equal value '(:unboxed . :home))
        collect `(sys.lap-x86:mov64 (:stack ,i) nil))
     ;; ## Set GC flags here.
     ;; Emit the argument count test.
     (cond ((lambda-information-rest-arg lambda)
	    ;; If there are no required parameters, then don't generate a lower-bound check.
	    (when (lambda-information-required-args lambda)
	      ;; Minimum number of arguments.
	      (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		    `(sys.lap-x86:jl ,invalid-arguments-label))))
	   ((and (lambda-information-required-args lambda)
		 (lambda-information-optional-args lambda))
	    ;; A range.
	    (list `(sys.lap-x86:mov32 :eax :ecx)
                  `(sys.lap-x86:sub32 :eax ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		  `(sys.lap-x86:cmp32 :eax ,(fixnum-to-raw (length (lambda-information-optional-args lambda))))
		  `(sys.lap-x86:ja ,invalid-arguments-label)))
	   ((lambda-information-optional-args lambda)
	    ;; Maximum number of arguments.
	    (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-optional-args lambda))))
		  `(sys.lap-x86:ja ,invalid-arguments-label)))
	   ((lambda-information-required-args lambda)
	    ;; Exact number of arguments.
	    (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		  `(sys.lap-x86:jne ,invalid-arguments-label)))
	   ;; No arguments
	   (t (list `(sys.lap-x86:test32 :ecx :ecx)
		    `(sys.lap-x86:jnz ,invalid-arguments-label)))))))

(defun emit-rest-list (lambda arg-registers)
  (let* ((rest-arg (lambda-information-rest-arg lambda))
         (regular-argument-count (+ (length (lambda-information-required-args lambda))
                                    (length (lambda-information-optional-args lambda))))
         (rest-loop-head (gensym "REST-LOOP-HEAD"))
         (rest-loop-test (gensym "REST-LOOP-TEST"))
         (rest-loop-end (gensym "REST-LOOP-END"))
         (dx-rest (lexical-variable-dynamic-extent rest-arg))
         (reg-arg-tags (loop for reg in arg-registers collect (list (gensym))))
         (control-slots (allocate-control-stack-slots 4))
         (rest-head nil)
         (rest-tail nil))
    (setf rest-head (find-stack-slot)
          (aref *stack-values* rest-head) (cons :rest-head :home))
    (setf rest-tail (find-stack-slot)
          (aref *stack-values* rest-tail) (cons :rest-tail :home))
    ;; Assemble the rest list into R13.
    ;; RCX holds the argument count.
    ;; RBX and R13 are free. Argument registers may or may not be free
    ;; depending on the number of required/optional arguments.
    (unless dx-rest
      ;; Only save the arg registers when creating a full cons.
      (loop for slot = (find-stack-slot)
         for tag in reg-arg-tags
         for reg in arg-registers
         do
           (setf (aref *stack-values* slot) tag)
           (emit `(sys.lap-x86:mov64 (:stack ,slot) ,reg))
           (push tag *load-list*)))
    ;; Number of arguments processed. Skip register arguments.
    (emit `(sys.lap-x86:mov64 ,(control-stack-slot-ea control-slots) ,(fixnum-to-raw (max regular-argument-count 5))))
    ;; Number of supplied arguments
    (emit `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-slots 1)) :rcx))
    ;; Create the result cell. Always create this as dynamic-extent, it
    ;; is only used during rest-list creation.
    (emit `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-slots 2)) nil)
          `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-slots 3)) nil)
          `(sys.lap-x86:lea64 :rbx (:cfp ,(+ (control-stack-frame-offset (+ control-slots 3)) sys.int::+tag-cons+))))
    ;; Stash in the result slot and the tail slot.
    (emit `(sys.lap-x86:mov64 (:stack ,rest-head) :rbx)
          `(sys.lap-x86:mov64 (:stack ,rest-tail) :rbx))
    ;; Add register arguments to the list.
    (cond
      (dx-rest
       (loop for i from regular-argument-count
          for reg in arg-registers
          do (emit `(sys.lap-x86:cmp64 :rcx ,(fixnum-to-raw i))
                   `(sys.lap-x86:jle ,rest-loop-end)
                   `(sys.lap-x86:sub64 :csp 16)
                   `(sys.lap-x86:mov64 (:csp 0) nil)
                   `(sys.lap-x86:mov64 (:csp 8) nil)
                   `(sys.lap-x86:lea64 :rbx (:csp #.sys.int::+tag-cons+))
                   `(sys.lap-x86:mov64 (:car :rbx) ,reg)
                   `(sys.lap-x86:mov64 :r8 (:stack ,rest-tail))
                   `(sys.lap-x86:mov64 (:cdr :r8) :rbx)
                   `(sys.lap-x86:mov64 (:stack ,rest-tail) :rbx))))
      (t
       (loop for i from regular-argument-count
          for tag in reg-arg-tags do
            (emit `(sys.lap-x86:cmp64 ,(control-stack-slot-ea (+ control-slots 1)) ,(fixnum-to-raw i))
                  `(sys.lap-x86:jle ,rest-loop-end))
            (load-in-r8 tag t)
            (emit `(sys.lap-x86:mov64 :r9 nil)
                  `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
                  `(sys.lap-x86:mov64 :r13 (:constant cons))
                  `(sys.lap-x86:call (:symbol-function :r13))
                  `(sys.lap-x86:mov64 :rbx (:stack ,rest-tail))
                  `(sys.lap-x86:mov64 (:cdr :rbx) :r8)
                  `(sys.lap-x86:mov64 (:stack ,rest-tail) :r8)))))
    ;; All register arguments are in the list.
    ;; Now add the stack arguments.
    (emit `(sys.lap-x86:mov64 :rax ,(control-stack-slot-ea control-slots))
          `(sys.lap-x86:jmp ,rest-loop-test)
          rest-loop-head)
    ;; Load current value. -5 + 2. Skip registers, return address & fp.
    (emit `(sys.lap-x86:mov64 :r8 (:cfp :rax -24)))
    ;; Create a new cons.
    (cond
      (dx-rest
       (emit `(sys.lap-x86:sub64 :csp 16)
             `(sys.lap-x86:mov64 (:csp 0) nil)
             `(sys.lap-x86:mov64 (:csp 8) nil)
             `(sys.lap-x86:lea64 :rbx (:csp #.sys.int::+tag-cons+))
             `(sys.lap-x86:mov64 (:car :rbx) :r8)
             `(sys.lap-x86:mov64 :r8 (:stack ,rest-tail))
             `(sys.lap-x86:mov64 (:cdr :r8) :rbx)
             `(sys.lap-x86:mov64 (:stack ,rest-tail) :rbx)))
      (t
       (emit `(sys.lap-x86:mov64 :r9 nil)
             `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
             `(sys.lap-x86:mov64 :r13 (:constant cons))
             `(sys.lap-x86:call (:symbol-function :r13))
             `(sys.lap-x86:mov64 :r9 (:stack ,rest-tail))
             `(sys.lap-x86:mov64 (:cdr :r9) :r8)
             `(sys.lap-x86:mov64 (:stack ,rest-tail) :r8))))
    ;; Advance processed count & test for end.
    (emit `(sys.lap-x86:add64 ,(control-stack-slot-ea control-slots) ,(fixnum-to-raw 1))
          `(sys.lap-x86:mov64 :rax ,(control-stack-slot-ea control-slots))
          rest-loop-test
          `(sys.lap-x86:cmp64 :rax ,(control-stack-slot-ea (+ control-slots 1)))
          `(sys.lap-x86:jl ,rest-loop-head)
          rest-loop-end)
    ;; The rest list has been created!
    (let ((ofs (find-stack-slot)))
      (setf (aref *stack-values* ofs) (cons rest-arg :home))
      (emit `(sys.lap-x86:mov64 :r8 (:stack ,rest-head))
            `(sys.lap-x86:mov64 :r8 (:cdr :r8))
            `(sys.lap-x86:mov64 (:stack ,ofs) :r8)))
    ;; Flush the two temps.
    (setf (aref *stack-values* rest-head) nil
          (aref *stack-values* rest-tail) nil)))

(defun cg-form (form)
  (flet ((save-tag (tag)
	   (when (and tag *for-value* (not (keywordp tag)))
	     (push tag *load-list*))
	   tag))
    (etypecase form
      (cons (case (first form)
	      ((block) (save-tag (cg-block form)))
	      ((go) (cg-go form))
	      ((if) (save-tag (cg-if form)))
	      ((let) (cg-let form))
	      ((load-time-value) (error "LOAD-TIME-VALUE seen in CG-FORM."))
	      ((multiple-value-bind) (save-tag (cg-multiple-value-bind form)))
	      ((multiple-value-call) (save-tag (cg-multiple-value-call form)))
	      ((multiple-value-prog1) (save-tag (cg-multiple-value-prog1 form)))
	      ((progn) (cg-progn form))
	      ((quote) (cg-quote form))
	      ((return-from) (cg-return-from form))
	      ((setq) (cg-setq form))
	      ((tagbody) (cg-tagbody form))
	      ((the) (cg-the form))
	      ((unwind-protect) (error "UWIND-PROTECT not lowered."))
              ((sys.int::%jump-table) (cg-jump-table form))
	      (t (save-tag (cg-function-form form)))))
      (lexical-variable
       (save-tag (cg-variable form)))
      (lambda-information
       (let ((tag (cg-lambda form)))
         (when (and (consp tag)
                    (symbolp (car tag))
                    (null (cdr tag))
                    (not (eql 'quote (car tag))))
           (save-tag tag))
         tag)))))

(defun cg-block (form)
  (let* ((info (second form))
         (exit-label (gensym "block"))
         (escapes (block-information-env-var info))
         (*for-value* *for-value*))
    ;; Allowing predicate values here is too complicated.
    (when (eql *for-value* :predicate)
      (setf *for-value* t))
    ;; Disable tail calls when the BLOCK escapes.
    ;; TODO: When tailcalling, configure the escaping block so
    ;; control returns to the caller.
    (when (and escapes (eql *for-value* :tail))
      (setf *for-value* :multiple))
    (setf (block-information-return-mode info) *for-value*
          (block-information-count info) 0)
    (when escapes
      (smash-r8)
      (let ((slot (find-stack-slot))
            (control-info (allocate-control-stack-slots 4)))
        (setf (aref *stack-values* slot) (cons info :home))
        ;; Construct jump info.
        (emit `(sys.lap-x86:lea64 :rax (:rip ,exit-label))
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 3)) :rax)
              `(sys.lap-x86:gs)
              `(sys.lap-x86:mov64 :rax (,+binding-stack-gs-offset+))
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 2)) :rax)
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 1)) :csp)
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 0)) :cfp)
              ;; Save pointer to info
              `(sys.lap-x86:lea64 :rax ,(control-stack-slot-ea (+ control-info 3)))
              `(sys.lap-x86:mov64 (:stack ,slot) :rax))))
    (let* ((*rename-list* (cons (list (second form) exit-label) *rename-list*))
           (stack-slots (set-up-for-branch))
           (tag (cg-form `(progn ,@(cddr form)))))
      (cond ((and *for-value* tag (/= (block-information-count info) 0))
             ;; Returning a value, exit is reached normally and there were return-from forms reached.
             (let ((return-mode nil))
               (ecase *for-value*
                 ((:multiple :tail)
                  (unless (eql tag :multiple)
                    (load-multiple-values tag)
                    (smash-r8))
                  (setf return-mode :multiple))
                 (t (load-in-r8 tag t)
                    (smash-r8)
                    (setf return-mode (list (gensym)))))
               (emit exit-label)
               (setf *stack-values* (copy-stack-values stack-slots)
                     *r8-value* return-mode)))
            ((and *for-value* tag)
             ;; Returning a value, exit is reached normally, but no return-from forms were reached.
             tag)
            ((and *for-value* (/= (block-information-count info) 0))
             ;; Returning a value, exit is not reached normally, but there were return-from forms reached.
             (smash-r8)
             (emit exit-label)
             (setf *stack-values* (copy-stack-values stack-slots)
                   *r8-value* (if (member *for-value* '(:multiple :tail))
                                  :multiple
                                  (list (gensym)))))
            ((/= (block-information-count info) 0)
             ;; Not returning a value, but there were return-from forms reached.
             (smash-r8)
             (emit exit-label)
             (setf *stack-values* (copy-stack-values stack-slots)
                   *r8-value* (list (gensym))))
            ;; No value returned, no return-from forms reached.
            (t nil)))))

(defun cg-go (form)
  (let ((tag (assoc (second form) *rename-list*)))
    (smash-r8)
    (cond (tag ;; Local jump.
           (emit `(sys.lap-x86:jmp ,(second tag))))
          (t ;; Non-local exit.
           (let ((tagbody-tag (let ((*for-value* t))
                                (cg-form (third form)))))
             (load-in-r8 tagbody-tag t)
             ;; R8 holds the tagbody info.
             (emit ;; Restore registers.
                   `(sys.lap-x86:mov64 :csp (:r8 16))
                   `(sys.lap-x86:mov64 :cfp (:r8 24))
                   ;; GO GO GO!
                   `(sys.lap-x86:mov64 :rax (:r8 0))
                   `(sys.lap-x86:add64 :rax (:rax ,(* (position (second form)
                                                                (tagbody-information-go-tags
                                                                 (go-tag-tagbody (second form))))
                                                      8)))
                   `(sys.lap-x86:jmp :rax)))))
    'nil))

(defun branch-to (label))
(defun emit-label (label)
  (emit label))

(defun tag-saved-on-stack-p (tag)
  (dotimes (i (length *stack-values*) nil)
    (let ((x (aref *stack-values* i)))
      (when (or (eq tag x)
		(and (consp tag) (consp x)
		     (eql (car tag) (car x))
		     (eql (cdr tag) (cdr x))))
	(return t)))))

(defun set-up-for-branch ()
  ;; Save variables on the load list that might be modified to the stack.
  (smash-r8)
  (dolist (l *load-list*)
    (when (and (consp l) (lexical-variable-p (car l))
	       (not (eql (lexical-variable-write-count (car l)) 0)))
      ;; Don't save if there is something satisfying this already.
      (multiple-value-bind (loc true-tag)
	  (value-location l)
	(declare (ignore loc))
	(unless (tag-saved-on-stack-p true-tag)
	  (load-in-r8 l nil)
	  (smash-r8 t)))))
  (let ((new-values (make-array (length *stack-values*) :initial-contents *stack-values*)))
    ;; Now flush any values that aren't there to satisfy the load list.
    (dotimes (i (length new-values))
      (when (condemed-p (aref new-values i))
	(setf (aref new-values i) nil)))
    new-values))

(defun copy-stack-values (values)
  "Copy the VALUES array, ensuring that it's at least as long as the current *stack-values* and is adjustable."
  (let ((new (make-array (length *stack-values*) :adjustable t :fill-pointer t :initial-element nil)))
    (setf (subseq new 0) values)
    new))

;;; (predicate inverse jump-instruction cmov-instruction)
(defparameter *predicate-instructions*
  '((:o  :no  sys.lap-x86:jo   sys.lap-x86:cmov64o)
    (:no :o   sys.lap-x86:jno  sys.lap-x86:cmov64no)
    (:b  :nb  sys.lap-x86:jb   sys.lap-x86:cmov64b)
    (:nb :b   sys.lap-x86:jnb  sys.lap-x86:cmov64nb)
    (:c  :nc  sys.lap-x86:jc   sys.lap-x86:cmov64c)
    (:nc :c   sys.lap-x86:jnc  sys.lap-x86:cmov64nc)
    (:ae :nae sys.lap-x86:jae  sys.lap-x86:cmov64ae)
    (:nae :ae sys.lap-x86:jnae sys.lap-x86:cmov64nae)
    (:e  :ne  sys.lap-x86:je   sys.lap-x86:cmov64e)
    (:ne :e   sys.lap-x86:jne  sys.lap-x86:cmov64ne)
    (:z  :nz  sys.lap-x86:jz   sys.lap-x86:cmov64z)
    (:nz :z   sys.lap-x86:jnz  sys.lap-x86:cmov64nz)
    (:be :nbe sys.lap-x86:jbe  sys.lap-x86:cmov64be)
    (:nbe :be sys.lap-x86:jnbe sys.lap-x86:cmov64nbe)
    (:a  :na  sys.lap-x86:ja   sys.lap-x86:cmov64a)
    (:na :a   sys.lap-x86:jna  sys.lap-x86:cmov64na)
    (:s  :ns  sys.lap-x86:js   sys.lap-x86:cmov64s)
    (:ns :s   sys.lap-x86:jns  sys.lap-x86:cmov64ns)
    (:p  :np  sys.lap-x86:jp   sys.lap-x86:cmov64p)
    (:np :p   sys.lap-x86:jnp  sys.lap-x86:cmov64np)
    (:pe :po  sys.lap-x86:jpe  sys.lap-x86:cmov64pe)
    (:po :pe  sys.lap-x86:jpo  sys.lap-x86:cmov64po)
    (:l  :nl  sys.lap-x86:jl   sys.lap-x86:cmov64l)
    (:nl :l   sys.lap-x86:jnl  sys.lap-x86:cmov64nl)
    (:ge :nge sys.lap-x86:jge  sys.lap-x86:cmov64ge)
    (:nge :ge sys.lap-x86:jnge sys.lap-x86:cmov64nge)
    (:le :nle sys.lap-x86:jle  sys.lap-x86:cmov64le)
    (:nle :le sys.lap-x86:jnle sys.lap-x86:cmov64nle)
    (:g  :ng  sys.lap-x86:jg   sys.lap-x86:cmov64g)
    (:ng :g   sys.lap-x86:jng  sys.lap-x86:cmov64ng)))

(defun predicate-info (pred)
  (or (assoc pred *predicate-instructions*)
      (error "Unknown predicate ~S." pred)))

(defun invert-predicate (pred)
  (second (predicate-info pred)))

(defun load-predicate (pred)
  (smash-r8)
  (emit `(sys.lap-x86:mov64 :r8 nil)
        `(sys.lap-x86:mov64 :r9 t)
        `(,(fourth (predicate-info pred)) :r8 :r9)))

(defun predicate-result (pred)
  (cond ((eql *for-value* :predicate)
         pred)
        (t (load-predicate pred)
           (setf *r8-value* (list (gensym))))))

(defun cg-if (form)
  (let* ((else-label (gensym))
	 (end-label (gensym))
	 (test-tag (let ((*for-value* :predicate))
		     (cg-form (second form))))
	 (branch-count 0)
	 (stack-slots (set-up-for-branch))
	 (loc (when (and test-tag (not (keywordp test-tag)))
                (value-location test-tag t))))
    (when (null test-tag)
      (return-from cg-if))
    (cond ((keywordp test-tag)) ; Nothing for predicates.
          ((and (consp loc) (eq (first loc) :stack))
	   (emit `(sys.lap-x86:cmp64 (:stack ,(second loc)) nil)))
	  (t (load-in-r8 test-tag)
	     (emit `(sys.lap-x86:cmp64 :r8 nil))))
    (let ((r8-at-cond *r8-value*)
	  (stack-at-cond (make-array (length *stack-values*) :initial-contents *stack-values*)))
      ;; This is a little dangerous and relies on SET-UP-FOR-BRANCH not
      ;; changing the flags.
      (cond ((keywordp test-tag)
             ;; Invert the sense.
             (emit `(,(third (predicate-info (invert-predicate test-tag))) ,else-label)))
            (t (emit `(sys.lap-x86:je ,else-label))))
      (branch-to else-label)
      (let ((tag (cg-form (third form))))
	(when tag
	  (when *for-value*
            (case *for-value*
              ((:multiple :tail) (load-multiple-values tag))
              (:predicate (if (keywordp tag)
                              (load-predicate tag)
                              (load-in-r8 tag t)))
              (t (load-in-r8 tag t))))
	  (emit `(sys.lap-x86:jmp ,end-label))
	  (incf branch-count)
	  (branch-to end-label)))
      (setf *r8-value* r8-at-cond
	    *stack-values* (copy-stack-values stack-at-cond))
      (emit-label else-label)
      (let ((tag (cg-form (fourth form))))
	(when tag
	  (when *for-value*
            (case *for-value*
              ((:multiple :tail) (load-multiple-values tag))
              (:predicate (if (keywordp tag)
                              (load-predicate tag)
                              (load-in-r8 tag t)))
              (t (load-in-r8 tag t))))
	  (incf branch-count)
	  (branch-to end-label)))
      (emit-label end-label)
      (setf *stack-values* (copy-stack-values stack-slots))
      (unless (zerop branch-count)
        (cond ((member *for-value* '(:multiple :tail))
               (setf *r8-value* :multiple))
              (t (setf *r8-value* (list (gensym)))))))))

(defun localp (var)
  (or (null (lexical-variable-used-in var))
      (and (null (cdr (lexical-variable-used-in var)))
	   (eq (car (lexical-variable-used-in var)) (lexical-variable-definition-point var)))))

(defun cg-let (form)
  (let* ((bindings (second form))
         (variables (mapcar 'first bindings))
         (body (cddr form)))
    ;; Ensure there are no non-local variables or special bindings.
    (assert (every (lambda (x)
                     (and (lexical-variable-p x)
                          (localp x)))
                   variables))
    (dolist (b (second form))
      (let* ((var (first b))
             (init-form (second b)))
        (cond ((zerop (lexical-variable-use-count var))
               (let ((*for-value* nil))
                 (cg-form init-form)))
              (t
               (let ((slot (find-stack-slot)))
                 (setf (aref *stack-values* slot) (cons var :home))
                 (let* ((*for-value* t)
                        (tag (cg-form init-form)))
                   (load-in-r8 tag t)
                   (setf *r8-value* (cons var :dup))
                   (emit `(sys.lap-x86:mov64 (:stack ,slot) :r8))))))))
    (cg-form `(progn ,@body))))

(defun gensym-many (things)
  (loop for x in things collect (gensym)))

(defun cg-multiple-value-bind (form)
  (let ((variables (second form))
        (value-form (third form))
        (body (cdddr form)))
    ;; Ensure there are no non-local variables or special bindings.
    (assert (every (lambda (x)
                     (and (lexical-variable-p x)
                          (localp x)))
                   variables))
    ;; Initialize local variables to NIL.
    (dolist (var variables)
      (when (not (zerop (lexical-variable-use-count var)))
        (let ((slot (find-stack-slot)))
          (setf (aref *stack-values* slot) (cons var :home))
          (emit `(sys.lap-x86:mov64 (:stack ,slot) nil)))))
    ;; Compile the value-form.
    (let ((value-tag (let ((*for-value* :multiple))
                       (cg-form value-form))))
      (load-multiple-values value-tag))
    ;; Bind variables.
    (let* ((jump-targets (gensym-many variables))
           (no-vals-label (gensym))
           (var-count (length variables))
           (value-locations (nreverse (subseq '(:r8 :r9 :r10 :r11 :r12) 0 (min 5 var-count)))))
      (dotimes (i (- var-count 5))
        (push i value-locations))
      (dotimes (i var-count)
        (emit `(sys.lap-x86:cmp64 :rcx ,(fixnum-to-raw (- var-count i)))
              `(sys.lap-x86:jae ,(nth i jump-targets))))
      (emit `(sys.lap-x86:jmp ,no-vals-label))
      (loop for var in (reverse variables)
         for label in jump-targets do
           (emit label)
           (cond ((zerop (lexical-variable-use-count var))
                  (pop value-locations))
                 (t (let ((register (cond ((integerp (first value-locations))
                                           (emit `(sys.lap-x86:gs)
                                                 `(sys.lap-x86:mov64 :r13 (,(+ (- 8 sys.int::+tag-array-like+)
                                                                               (* (+ sys.int::+stack-group-offset-mv-slots+
                                                                                     (first value-locations)) 8)))))
                                           :r13)
                                          (t (pop value-locations)))))
                      (emit `(sys.lap-x86:mov64 (:stack ,(position (cons var :home)
                                                                   *stack-values*
                                                                   :test 'equal))
                                                ,register))))))
      (emit no-vals-label))
    (cg-form `(progn ,@body))))

(defun cg-multiple-value-call (form)
  (let ((function (second form))
        (value-forms (cddr form)))
    (cond ((null value-forms)
           ;; Just like a regular call.
           (cg-function-form `(funcall ,function)))
          ((null (cdr value-forms))
           ;; Single value form.
           (let ((fn-tag (let ((*for-value* t)) (cg-form function)))
                 (stack-pointer-save-area (allocate-control-stack-slots 1)))
             (when (not fn-tag)
               (return-from cg-multiple-value-call nil))
             (let ((value-tag (let ((*for-value* :multiple))
                                (cg-form (first value-forms)))))
               (when (not value-tag)
                 (return-from cg-multiple-value-call nil))
               (load-multiple-values value-tag)
               (emit `(sys.lap-x86:mov64 ,(control-stack-slot-ea stack-pointer-save-area) :rsp))
               (multiple-values-to-stack)
               (smash-r8)
               (load-in-reg :r13 fn-tag t)
               (let ((type-error-label (gensym))
                     (function-label (gensym))
                     (out-label (gensym)))
                 (emit-trailer (type-error-label)
                   (raise-type-error :r13 '(or function symbol)))
                 (emit `(sys.lap-x86:mov8 :al :r13l)
                       `(sys.lap-x86:and8 :al #b1111)
                       `(sys.lap-x86:cmp8 :al ,sys.int::+tag-function+)
                       `(sys.lap-x86:je ,function-label)
                       `(sys.lap-x86:cmp8 :al ,sys.int::+tag-symbol+)
                       `(sys.lap-x86:jne ,type-error-label)
                       `(sys.lap-x86:call (:symbol-function :r13)))
                 (emit `(sys.lap-x86:jmp ,out-label))
                 (emit function-label
                       `(sys.lap-x86:call :r13))
                 (emit out-label)
                 (emit `(sys.lap-x86:mov64 :rsp ,(control-stack-slot-ea stack-pointer-save-area)))
                 (cond ((member *for-value* '(:multiple :tail))
                        :multiple)
                       (t (setf *r8-value* (list (gensym)))))))))
          (t (error "M-V-CALL with >1 form not lowered")))))

(defun cg-multiple-value-prog1 (form)
  (cond
    ((null *for-value*)
     ;; Not for value
     (cg-progn form))
    (t (let ((tag (let ((*for-value* (case *for-value*
                                       (:predicate t)
                                       (:tail :multiple)
                                       (t *for-value*))))
                    (cg-form (second form))))
             (save-area (allocate-control-stack-slots 2))
             (reg-arg-tags (loop for reg in '(:r8 :r9 :r10 :r11 :r12) collect (list (gensym)))))
         (smash-r8)
         (when (eql tag :multiple)
           (loop for slot = (find-stack-slot)
              for tag in reg-arg-tags
              for reg in '(:r8 :r9 :r10 :r11 :r12)
              do
                (setf (aref *stack-values* slot) tag)
                (emit `(sys.lap-x86:mov64 (:stack ,slot) ,reg))
                (push tag *load-list*))
           (multiple-values-to-stack)
           (emit `(sys.lap-x86:mov64 ,(control-stack-slot-ea save-area) :rcx)
                 `(sys.lap-x86:mov64 ,(control-stack-slot-ea (1+ save-area)) :rsp)))
         (let ((*for-value* nil))
           (when (not (cg-progn `(progn ,@(cddr form))))
             ;; No return.
             (setf *load-list* (delete tag *load-list*))
             (return-from cg-multiple-value-prog1 'nil)))
         (smash-r8)
         ;; Drop the tag from the load-list to prevent duplicates caused by cg-form
         (setf *load-list* (delete tag *load-list*))
         (when (eql tag :multiple)
           (emit `(sys.lap-x86:mov64 :rcx ,(control-stack-slot-ea save-area))
                 `(sys.lap-x86:mov64 :rsi ,(control-stack-slot-ea (1+ save-area))))
           (stack-to-multiple-values)
           (loop for reg in '(:r8 :r9 :r10 :r11 :r12)
              for tag in reg-arg-tags
              do (load-in-reg reg tag t)))
         tag))))

(defun cg-progn (form)
  (if (rest form)
      (do ((i (rest form) (rest i)))
	  ((endp (rest i))
	   (cg-form (first i)))
	(let* ((*for-value* nil)
	       (tag (cg-form (first i))))
	  (when (null tag)
	    (return-from cg-progn 'nil))))
      (cg-form ''nil)))

(defun cg-quote (form)
  form)

(defun cg-return-from (form)
  (let* ((local-info (assoc (second form) *rename-list*))
         (*for-value* (block-information-return-mode (second form)))
         (target-tag (when (not local-info)
                       (let ((*for-value* t))
                         (cg-form (fourth form)))))
         (tag (cg-form (third form))))
    (unless tag (return-from cg-return-from nil))
    (cond ((member *for-value* '(:multiple :tail))
           (load-multiple-values tag))
          (*for-value*
           (load-in-r8 tag t)))
    (incf (block-information-count (second form)))
    (smash-r8)
    (cond (local-info ;; Local jump.
           (emit `(sys.lap-x86:jmp ,(second local-info))))
          (t ;; Non-local exit.
           (load-in-reg :rax target-tag t)
           ;; Restore registers.
           (emit `(sys.lap-x86:mov64 :csp (:rax 16))
                 `(sys.lap-x86:mov64 :cfp (:rax 24))
                 ;; GO GO GO!
                 `(sys.lap-x86:jmp (:rax 0)))))
    'nil))

(defun find-variable-home (var)
  (dotimes (i (length *stack-values*)
	    (error "No home for ~S?" var))
    (let ((x (aref *stack-values* i)))
      (when (and (consp x) (eq (car x) var) (eq (cdr x) :home))
	(return i)))))

(defun cg-setq (form)
  (let ((var (second form))
	(val (third form)))
    (assert (localp var))
    ;; Copy var if there are unsatisfied tags on the load list.
    (dolist (l *load-list*)
      (when (and (consp l) (eq (car l) var))
        ;; Don't save if there is something satisfying this already.
        (multiple-value-bind (loc true-tag)
            (value-location l)
          (declare (ignore loc))
          (unless (tag-saved-on-stack-p true-tag)
            (load-in-r8 l nil)
            (smash-r8 t)))))
    (let ((tag (let ((*for-value* t)) (cg-form val)))
          (home (find-variable-home var)))
      (when (null tag)
        (return-from cg-setq))
      (load-in-r8 tag t)
      (emit `(sys.lap-x86:mov64 (:stack ,home) :r8))
      (setf *r8-value* (cons var :dup))
      (cons var (incf *run-counter* 2)))))

(defun tagbody-localp (info)
  (dolist (tag (tagbody-information-go-tags info) t)
    (unless (or (null (go-tag-used-in tag))
		(and (null (cdr (go-tag-used-in tag)))
		     (eq (car (go-tag-used-in tag)) (tagbody-information-definition-point info))))
      (return nil))))

;;; FIXME: Everything must return a valid tag if control flow follows.
(defun cg-tagbody (form)
  (let ((*for-value* nil)
	(stack-slots nil)
	(*rename-list* *rename-list*)
	(last-value t)
        (escapes (not (tagbody-localp (second form))))
        (jump-table (gensym))
        (tag-labels (mapcar (lambda (tag)
                              (declare (ignore tag))
                              (gensym))
                            (tagbody-information-go-tags (second form)))))
    (when escapes
      ;; Emit the jump-table.
      ;; TODO: Prune local labels out.
      (emit-trailer (jump-table)
        (dolist (i tag-labels)
          (emit `(:d64/le (- ,i ,jump-table)))))
      (smash-r8)
      (let ((slot (find-stack-slot))
            (control-info (allocate-control-stack-slots 6)))
        ;; Construct jump info.
        (emit `(sys.lap-x86:lea64 :rax (:rip ,jump-table))
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 3)) :rax)
              `(sys.lap-x86:gs)
              `(sys.lap-x86:mov64 :rax (,+binding-stack-gs-offset+))
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 2)) :rax)
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 1)) :csp)
              `(sys.lap-x86:mov64 ,(control-stack-slot-ea (+ control-info 0)) :cfp)
              ;; Save in the environment.
              `(sys.lap-x86:lea64 :rax ,(control-stack-slot-ea (+ control-info 3)))
              `(sys.lap-x86:mov64 (:stack ,slot) :rax))
        (setf (aref *stack-values* slot) (cons (second form) :home))))
    (setf stack-slots (set-up-for-branch))
    (mapcar (lambda (tag label)
              (push (list tag label) *rename-list*))
            (tagbody-information-go-tags (second form)) tag-labels)
    (dolist (stmt (cddr form))
      (if (go-tag-p stmt)
	  (progn
	    (smash-r8)
	    (setf *stack-values* (copy-stack-values stack-slots))
	    (setf last-value t)
	    (emit (second (assoc stmt *rename-list*))))
	  (setf last-value (cg-form stmt))))
    (if last-value
	''nil
	'nil)))

(defun cg-the (form)
  (cg-form (third form)))

(defun fixnump (object)
  (typep object '(signed-byte 61)))

(defun value-location (tag &optional kill)
  (when kill
    (setf *load-list* (delete tag *load-list*)))
  (cond ((eq (car tag) 'quote)
	 (values (if (and (consp *r8-value*)
			  (eq (car *r8-value*) 'quote)
			  (eql (cadr tag) (cadr *r8-value*)))
		     :r8
		     tag)
		 tag))
	((null (cdr tag))
	 (values (if (eq tag *r8-value*)
		     :r8
		     (dotimes (i (length *stack-values*)
			       (error "Cannot find tag ~S." tag))
		       (when (eq tag (aref *stack-values* i))
			 (return (list :stack i)))))
		 tag))
	((lexical-variable-p (car tag))
	 ;; Search for the lowest numbered time that is >= to the tag time.
	 (let ((best (when (and (consp *r8-value*) (eq (car *r8-value*) (car tag))
				(integerp (cdr *r8-value*)) (>= (cdr *r8-value*) (cdr tag)))
		       *r8-value*))
	       (best-loc :r8)
	       (home-loc nil)
	       (home nil))
	   (dotimes (i (length *stack-values*))
	     (let ((val (aref *stack-values* i)))
	       (when (and (consp val) (eq (car val) (car tag)))
		 (cond ((eq (cdr val) :home)
			(setf home (cons (car val) *run-counter*)
			      home-loc (list :stack i)))
		       ((and (integerp (cdr val)) (>= (cdr val) (cdr tag))
			     (or (null best)
				 (< (cdr val) (cdr best))))
			(setf best val
			      best-loc (list :stack i)))))))
	   (values (or (when best
			 best-loc)
		       ;; R8 might hold a duplicate (thanks to let or setq), use that instead of home.
		       (when (and *r8-value* (consp *r8-value*) (eq (car *r8-value*) (car tag)) (eq (cdr *r8-value*) :dup))
			 :r8)
		       home-loc
		       (error "Cannot find tag ~S." tag))
		   (or best
		       (when (and *r8-value* (consp *r8-value*) (eq (car *r8-value*) (car tag)) (eq (cdr *r8-value*) :dup))
			 *r8-value*)
		       home))))
	(t (error "What kind of tag is this? ~S" tag))))

(defun condemed-p (tag)
  (cond ((eq (cdr tag) :home)
	 nil)
	((eq (cdr tag) :dup)
	 t)
	(t (dolist (v *load-list* t)
	     (when (eq (first tag) (first v))
	       (if (null (rest tag))
		   (return nil)
		   ;; Figure out the best tag that satisfies this load.
		   (let ((best (when (and (consp *r8-value*) (eq (car *r8-value*) (car tag))
					  (integerp (cdr *r8-value*)) (>= (cdr *r8-value*) (cdr tag)))
				 *r8-value*)))
		     (dotimes (i (length *stack-values*))
		       (let ((val (aref *stack-values* i)))
			 (when (and (consp val) (eq (car val) (car v))
				    (integerp (cdr val)) (>= (cdr val) (cdr v))
				    (or (null best)
					(< (cdr val) (cdr best))))
			   (setf best val))))
		     (when (eq best tag)
		       (return nil)))))))))

(defun find-stack-slot ()
  ;; Find a free stack slot, or allocate a new one.
  (dotimes (i (length *stack-values*)
	    (vector-push-extend nil *stack-values*))
    (when (or (null (aref *stack-values* i))
	      (condemed-p (aref *stack-values* i)))
      (setf (aref *stack-values* i) nil)
      (return i))))

(defun smash-r8 (&optional do-not-kill-r8)
  "Check if the value in R8 is on the load-list and flush it to the stack if it is."
  ;; Avoid flushing if it's already on the stack.
  (when (and *r8-value*
             (not (eql *r8-value* :multiple))
	     (not (condemed-p *r8-value*))
	     (not (tag-saved-on-stack-p *r8-value*)))
    (let ((slot (find-stack-slot)))
      (setf (aref *stack-values* slot) *r8-value*)
      (emit `(sys.lap-x86:mov64 (:stack ,slot) :r8))))
  (unless do-not-kill-r8
    (setf *r8-value* nil)))

(defun load-constant (register value)
  (cond ((eql value 0)
	 (emit `(sys.lap-x86:xor64 ,register ,register)))
	((eq value 'nil)
	 (emit `(sys.lap-x86:mov64 ,register nil)))
	((eq value 't)
	 (emit `(sys.lap-x86:mov64 ,register t)))
	((fixnump value)
	 (emit `(sys.lap-x86:mov64 ,register ,(fixnum-to-raw value))))
	((characterp value)
	 (emit `(sys.lap-x86:mov64 ,register ,(character-to-raw value))))
	(t (emit `(sys.lap-x86:mov64 ,register (:constant ,value))))))

(defun load-multiple-values (tag)
  (cond ((eql tag :multiple))
        (t (load-in-r8 tag t)
           (emit `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))))))

(defun load-in-r8 (tag &optional kill)
  (multiple-value-bind (loc true-tag)
      (value-location tag nil)
    (unless (eq loc :r8)
      (smash-r8)
      (ecase (first loc)
	((quote) (load-constant :r8 (second loc)))
	((:stack) (emit `(sys.lap-x86:mov64 :r8 (:stack ,(second loc))))))
      (setf *r8-value* true-tag))
    (when kill
      (setf *load-list* (delete tag *load-list*)))))

(defun load-in-reg (reg tag &optional kill)
  (if (eql reg :r8)
      (load-in-r8 tag kill)
      (let ((loc (value-location tag nil)))
	(unless (eql loc reg)
	  (if (eql loc :r8)
	      (emit `(sys.lap-x86:mov64 ,reg :r8))
	      (ecase (first loc)
		((quote) (load-constant reg (second loc)))
		((:stack) (emit `(sys.lap-x86:mov64 ,reg (:stack ,(second loc))))))))
	(when kill
	  (setf *load-list* (delete tag *load-list*))))))

(defun flush-arguments-from-stack (arg-forms)
  (let ((stack-count (max 0 (- (length arg-forms) 5))))
    (when (plusp stack-count)
      (when (oddp stack-count) (incf stack-count))
      (emit `(sys.lap-x86:add64 :csp ,(* stack-count 8))))))

(defun prep-arguments-for-call (arg-forms)
  (when arg-forms
    (let ((args '())
	  (arg-count 0))
      (let ((*for-value* t))
	(dolist (f arg-forms)
	  (push (cg-form f) args)
	  (incf arg-count)
	  (when (null (first args))
	    ;; Non-local control transfer, don't actually need those results now.
	    (dolist (i (rest args))
	      (setf *load-list* (delete i *load-list*)))
	    (return-from prep-arguments-for-call nil))))
      (setf args (nreverse args))
      ;; Interrupts are not a problem here.
      ;; They switch stack groups and don't touch the Lisp stack.
      (let ((stack-count (- arg-count 5)))
	(when (plusp stack-count)
          (when (oddp stack-count)
            (incf stack-count))
          (emit `(sys.lap-x86:sub64 :csp ,(* stack-count 8)))
	  ;; Load values on the stack.
	  ;; Use r13 here to preserve whatever is in r8.
          ;; ### GC stuff here.
          (loop for i from 0
             for j in (nthcdr 5 args) do
               (load-in-reg :r13 j t)
               (emit `(sys.lap-x86:mov64 (:csp ,(* i 8)) :r13)))))
      ;; Load other values in registers.
      (when (> arg-count 4)
	(load-in-reg :r12 (nth 4 args) t))
      (when (> arg-count 3)
	(load-in-reg :r11 (nth 3 args) t))
      (when (> arg-count 2)
	(load-in-reg :r10 (nth 2 args) t))
      (when (> arg-count 1)
	(load-in-reg :r9 (nth 1 args) t))
      (when (> arg-count 0)
	(load-in-r8 (nth 0 args) t))))
  t)

;; Compile a VALUES form.
(defun cg-values (forms)
  (cond ((null forms)
         ;; No values.
         (cond ((member *for-value* '(:multiple :tail))
                ;; R8 must hold NIL.
                (load-in-r8 ''nil)
                (emit `(sys.lap-x86:xor32 :ecx :ecx))
                :multiple)
               (t (cg-form ''nil))))
        ((null (rest forms))
         ;; Single value.
         (let ((*for-value* t))
           (cg-form (first forms))))
        (t ;; Multiple-values
         (cond ((member *for-value* '(:multiple :tail))
                ;; The MV return convention happens to be almost identical
                ;; to the standard calling convention!
                (when (prep-arguments-for-call forms)
                  (load-constant :rcx (length forms))
                  (when (> (length forms) 5)
                    (emit `(sys.lap-x86:mov64 :rsi :rsp))
                    (stack-to-multiple-values))
                  :multiple))
               (t ;; VALUES behaves like PROG1 when not compiling for multiple values.
                (let ((tag (cg-form (first forms))))
                  (unless tag (return-from cg-values nil))
                  (let ((*for-value* nil))
                    (dolist (f (rest forms))
                      (when (not (cg-form f))
                        (setf *load-list* (delete tag *load-list*))
                        (return-from cg-values nil))))
                  tag))))))

;; ### TCE here
(defun cg-function-form (form)
  (let ((fn (when (not *suppress-builtins*)
              (match-builtin (first form) (length (rest form))))))
    (cond ((and (eql *for-value* :predicate)
                (or (eql (first form) 'null)
                    (eql (first form) 'not))
                (= (length form) 2))
           (let* ((tag (cg-form (second form)))
                  (loc (when (and tag (not (keywordp tag)))
                         (value-location tag t))))
             (cond ((null tag) nil)
                   ((keywordp tag)
                    ;; Invert the sense.
                    (invert-predicate tag))
                   ;; Perform (eql nil ...).
                   ((and (consp loc) (eq (first loc) :stack))
                    (emit `(sys.lap-x86:cmp64 (:stack ,(second loc)) nil))
                    :e)
                   (t (load-in-r8 tag)
                      (emit `(sys.lap-x86:cmp64 :r8 nil))
                      :e))))
          (fn
	   (let ((args '()))
	     (let ((*for-value* t))
	       (dolist (f (rest form))
		 (push (cg-form f) args)
		 (when (null (first args))
		   ;; Non-local control transfer, don't actually need those results now.
		   (dolist (i (rest args))
		     (setf *load-list* (delete i *load-list*)))
		   (return-from cg-function-form nil))))
	     (apply fn (nreverse args))))
	  ((and (eql (first form) 'funcall)
		(rest form))
	   (let* ((fn-tag (let ((*for-value* t)) (cg-form (second form))))
		  (type-error-label (gensym))
		  (function-label (gensym))
                  (out-label (gensym)))
	     (cond ((prep-arguments-for-call (cddr form))
		    (emit-trailer (type-error-label)
		      (raise-type-error :r13 '(or function symbol)))
		    (load-in-reg :r13 fn-tag t)
		    (smash-r8)
		    (load-constant :rcx (length (cddr form)))
                    (unless (typep (second form) 'lambda-information)
                      ;; Might be a symbol.
                      (emit `(sys.lap-x86:mov8 :al :r13l)
                            `(sys.lap-x86:and8 :al #b1111)
                            `(sys.lap-x86:cmp8 :al ,sys.int::+tag-function+)
                            `(sys.lap-x86:je ,function-label)
                            `(sys.lap-x86:cmp8 :al ,sys.int::+tag-symbol+)
                            `(sys.lap-x86:jne ,type-error-label))
                      (cond ((can-tail-call (cddr form))
                             (emit-tail-call '(:symbol-function :r13) (second form)))
                            (t (emit `(sys.lap-x86:call (:symbol-function :r13)))
                               (emit `(sys.lap-x86:jmp ,out-label)))))
                    (emit function-label)
                    (cond ((can-tail-call (cddr form))
                           (emit-tail-call :r13 (second form)))
                          (t (emit `(sys.lap-x86:call :r13))))
                    (emit out-label)
                    (flush-arguments-from-stack (cddr form))
                    (cond ((can-tail-call (cddr form)) nil)
                          ((member *for-value* '(:multiple :tail))
                           :multiple)
                          (t (setf *r8-value* (list (gensym))))))
		   (t ;; Flush the unused function.
		    (setf *load-list* (delete fn-tag *load-list*))))))
          ((eql (first form) 'values)
           (cg-values (rest form)))
	  (t (when (prep-arguments-for-call (rest form))
	       (load-constant :r13 (first form))
	       (smash-r8)
	       (load-constant :rcx (length (rest form)))
               (cond ((can-tail-call (rest form))
                      (emit-tail-call '(:symbol-function :r13) (first form))
                      nil)
                     (t (emit `(sys.lap-x86:call (:symbol-function :r13)))
                        (flush-arguments-from-stack (cdr form))
                        (cond ((member *for-value* '(:multiple :tail))
                               :multiple)
                              (t (setf *r8-value* (list (gensym))))))))))))

(defun can-tail-call (args)
  (and (eql *for-value* :tail)
       (<= (length args) 5)))

(defun emit-tail-call (where &optional what)
  (declare (ignorable what))
  #+nil(format t "Performing tail call to ~S in ~S~%"
          what (lambda-information-name *current-lambda*))
  (emit-return-code t)
  (emit `(sys.lap-x86:jmp ,where)))

(defun cg-variable (form)
  (assert (localp form))
  (cons form (incf *run-counter*)))

(defun cg-lambda (form)
  (list 'quote (codegen-lambda form)))

(defun raise-type-error (reg typespec)
  (unless (eql reg :r8)
    (emit `(sys.lap-x86:mov64 :r8 ,reg)))
  (load-constant :r9 typespec)
  (load-constant :r13 'sys.int::raise-type-error)
  (emit `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
	`(sys.lap-x86:call (:symbol-function :r13))
	`(sys.lap-x86:ud2))
  nil)

(defun fixnum-check (reg &optional (typespec 'fixnum))
  (let ((type-error-label (gensym)))
    (emit-trailer (type-error-label)
      (raise-type-error reg typespec))
    (emit `(sys.lap-x86:test64 ,reg #b111)
	  `(sys.lap-x86:jnz ,type-error-label))))

(defun cg-jump-table (form)
  (destructuring-bind (value &rest jumps) (cdr form)
    (let ((tag (let ((*for-value* t))
                 (cg-form value)))
          (jump-table (gensym "jump-table")))
      ;; Build the jump table.
      ;; Every jump entry must be a local GO with no special bindings.
      (emit-trailer (jump-table)
        (dolist (j jumps)
          (assert (and (listp j) (eql (first j) 'go)))
          (let ((go-tag (assoc (second j) *rename-list*)))
            (assert go-tag () "GO tag not local")
            (emit `(:d64/le (- ,(second go-tag) ,jump-table))))))
      ;; Jump.
      (load-in-r8 tag t)
      (smash-r8)
      (emit `(sys.lap-x86:lea64 :rax (:rip ,jump-table))
            `(sys.lap-x86:add64 :rax (:rax :r8))
            `(sys.lap-x86:jmp :rax))
      nil)))

(defun multiple-values-to-stack ()
  "Copy values in the sg-mv area to the stack. RCX holds the number of values to copy +5."
  (let ((loop-head (gensym))
        (loop-exit (gensym)))
    ;; RAX = n values to copy (fixnum).
    (emit `(sys.lap-x86:lea64 :rax (:rcx ,(- (* 5 8))))
          `(sys.lap-x86:cmp64 :rax 0)
          `(sys.lap-x86:jle ,loop-exit)
          `(sys.lap-x86:sub64 :rsp :rax)
          `(sys.lap-x86:mov64 :rdi :rsp)
          `(sys.lap-x86:mov32 :esi ,(+ (- 8 sys.int::+tag-array-like+)
                                       (* sys.int::+stack-group-offset-mv-slots+ 8)))
          loop-head
          `(sys.lap-x86:gs)
          `(sys.lap-x86:mov64 :rbx (:rsi))
          `(sys.lap-x86:mov64 (:rdi) :rbx)
          `(sys.lap-x86:add64 :rdi 8)
          `(sys.lap-x86:add64 :rsi 8)
          `(sys.lap-x86:sub64 :rax 8)
          `(sys.lap-x86:jae ,loop-head)
          loop-exit)))

(defun stack-to-multiple-values ()
  "Copy RCX-5 values from :RSI to the sg-mv area. Uses RAX, RDI & RSI."
  (let ((loop-head (gensym))
        (loop-exit (gensym)))
    ;; RAX = n values to copy (fixnum).
    (emit `(sys.lap-x86:lea64 :rax (:rcx ,(- (* 5 8))))
          `(sys.lap-x86:cmp64 :rax 0)
          `(sys.lap-x86:jle ,loop-exit)
          `(sys.lap-x86:sub64 :rsp :rax)
          `(sys.lap-x86:mov32 :edi ,(+ (- 8 sys.int::+tag-array-like+)
                                       (* sys.int::+stack-group-offset-mv-slots+ 8)))
          loop-head
          `(sys.lap-x86:mov64 :rbx (:rsi))
          `(sys.lap-x86:gs)
          `(sys.lap-x86:mov64 (:rdi) :rbx)
          `(sys.lap-x86:add64 :rdi 8)
          `(sys.lap-x86:add64 :rsi 8)
          `(sys.lap-x86:sub64 :rax 8)
          `(sys.lap-x86:jae ,loop-head)
          loop-exit)))
