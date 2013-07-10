(in-package :sys.int)

;;; (type tag size-in-bits 16-byte-aligned-p)
(defvar *array-info*
  '((bit #.+array-type-bit+ 1 nil)
    ((unsigned-byte 2) #.+array-type-unsigned-byte-2+ 2 nil)
    ((unsigned-byte 4) #.+array-type-unsigned-byte-4+ 4 nil)
    ((unsigned-byte 8) #.+array-type-unsigned-byte-8+ 8 nil)
    ((unsigned-byte 16) #.+array-type-unsigned-byte-16+ 16 nil)
    ((unsigned-byte 32) #.+array-type-unsigned-byte-32+ 32 nil)
    ((unsigned-byte 64) #.+array-type-unsigned-byte-64+ 64 nil)
    ((signed-byte 1) #.+array-type-signed-byte-1+ 1 nil)
    ((signed-byte 2) #.+array-type-signed-byte-2+ 2 nil)
    ((signed-byte 4) #.+array-type-signed-byte-4+ 4 nil)
    ((signed-byte 8) #.+array-type-signed-byte-8+ 8 nil)
    ((signed-byte 16) #.+array-type-signed-byte-16+ 16 nil)
    ((signed-byte 32) #.+array-type-signed-byte-32+ 32 nil)
    ((signed-byte 64) #.+array-type-signed-byte-64+ 64 nil)
    (base-char #.+array-type-base-char+ 8 nil)
    (character #.+array-type-character+ 32 nil)
    (single-float #.+array-type-single-float+ 32 t)
    (double-float #.+array-type-double-float+ 64 t)
    (long-float #.+array-type-long-float+ 128 t)
    (xmm-vector #.+array-type-xmm-vector+ 128 t)
    ((complex single-float) #.+array-type-complex-single-float+ 64 t)
    ((complex double-float) #.+array-type-complex-double-float+ 128 t)
    ((complex long-float) #.+array-type-complex-long-float+ 256 t)
    (t #.+array-type-t+ 64 nil)))

(defun %allocate-and-clear-array (length real-element-type &optional area)
  (let* ((info (assoc real-element-type *array-info* :test 'equal))
         (total-size (+ (if (fourth info) 64 0) ; padding for alignment.
                        (* length (third info)))))
    (unless (eql (first info) 't)
      ;; Not a simple-vector.
      (ecase area
        ((:dynamic) (error "Cannot allocate data vectors in dynamic space"))
        ((:static nil) (setf area :static))))
    ;; Align on a word boundary.
    (unless (zerop (rem total-size 64))
      (incf total-size (- 64 (rem total-size 64))))
    (%allocate-array-like (second info) (truncate total-size 64) length area)))

(defun %allocate-and-fill-array (length real-element-type initial-element &optional area)
  (let ((array (%allocate-and-clear-array length real-element-type area)))
    (dotimes (i length)
      (setf (aref array i) initial-element))
    array))

(defun make-simple-vector (length &optional area)
  "Allocate a SIMPLE-VECTOR with LENGTH elements.
Equivalent to (make-array length). Used by the compiler to
allocate environment frames."
  (%allocate-array-like +array-type-t+ length length area))

(defun signify (value width)
  "Convert an unsigned integer to a signed value."
  (if (logbitp (1- width) value)
      (logior value (lognot (1- (ash 1 width))))
      value))

(defun %simple-array-aref (array index)
  (ecase (%simple-array-type array)
    (#.+array-type-t+
     (svref array index))
    ((#.+array-type-base-char+ #.+array-type-character+)
     (schar array index))
    (#.+array-type-bit+
     (multiple-value-bind (offset bit)
         (truncate index 8)
       (ldb (byte 1 bit)
            (%array-like-ref-unsigned-byte-8 array offset))))
    (#.+array-type-unsigned-byte-2+
     (multiple-value-bind (offset bit)
         (truncate index 4)
       (ldb (byte 2 bit)
            (%array-like-ref-unsigned-byte-8 array offset))))
    (#.+array-type-unsigned-byte-4+
     (multiple-value-bind (offset bit)
         (truncate index 2)
       (ldb (byte 4 bit)
            (%array-like-ref-unsigned-byte-8 array offset))))
    (#.+array-type-unsigned-byte-8+
     (%array-like-ref-unsigned-byte-8 array index))
    (#.+array-type-unsigned-byte-16+
     (%array-like-ref-unsigned-byte-16 array index))
    (#.+array-type-unsigned-byte-32+
     (%array-like-ref-unsigned-byte-32 array index))
    (#.+array-type-unsigned-byte-64+
     (%array-like-ref-unsigned-byte-64 array index))
    (#.+array-type-signed-byte-1+
     (multiple-value-bind (offset bit)
         (truncate index 8)
       (signify (ldb (byte 1 bit)
                     (%array-like-ref-unsigned-byte-8 array offset))
                1)))
    (#.+array-type-signed-byte-2+
     (multiple-value-bind (offset bit)
         (truncate index 4)
       (signify (ldb (byte 2 bit)
                     (%array-like-ref-unsigned-byte-8 array offset))
                2)))
    (#.+array-type-signed-byte-4+
     (multiple-value-bind (offset bit)
         (truncate index 2)
       (signify (ldb (byte 4 bit)
                     (%array-like-ref-unsigned-byte-8 array offset))
                4)))
    (#.+array-type-signed-byte-8+
     (%array-like-ref-signed-byte-8 array index))
    (#.+array-type-signed-byte-16+
     (%array-like-ref-signed-byte-16 array index))
    (#.+array-type-signed-byte-32+
     (%array-like-ref-signed-byte-32 array index))
    (#.+array-type-signed-byte-64+
     (%array-like-ref-signed-byte-64 array index))
    (#.+array-type-single-float+
     (%integer-as-single-float (%array-like-ref-unsigned-byte-32 array index)))))

(defun (setf %simple-array-aref) (value array index)
  (ecase (%simple-array-type array)
    (#.+array-type-t+ ;; simple-vector
     (setf (svref array index) value))
    ((#.+array-type-base-char+ #.+array-type-character+)
     (setf (schar array index) value))
    (#.+array-type-bit+
     (check-type value bit)
     (multiple-value-bind (offset bit)
         (truncate index 8)
       (setf (ldb (byte 1 bit)
                  (%array-like-ref-unsigned-byte-8 array offset))
             value)))
    (#.+array-type-unsigned-byte-2+
     (check-type value (unsigned-byte 2))
     (multiple-value-bind (offset bit)
         (truncate index 4)
       (setf (ldb (byte 2 bit)
                  (%array-like-ref-unsigned-byte-8 array offset))
             value)))
    (#.+array-type-unsigned-byte-4+
     (check-type value (unsigned-byte 4))
     (multiple-value-bind (offset bit)
         (truncate index 2)
       (setf (ldb (byte 4 bit)
                  (%array-like-ref-unsigned-byte-8 array offset))
             value)))
    (#.+array-type-unsigned-byte-8+
     (setf (%array-like-ref-unsigned-byte-8 array index)
           value))
    (#.+array-type-unsigned-byte-16+
     (setf (%array-like-ref-unsigned-byte-16 array index)
           value))
    (#.+array-type-unsigned-byte-32+
     (setf (%array-like-ref-unsigned-byte-32 array index)
           value))
    (#.+array-type-unsigned-byte-64+
     (setf (%array-like-ref-unsigned-byte-64 array index)
           value))
    (#.+array-type-signed-byte-1+
     (check-type value (signed-byte 1))
     (multiple-value-bind (offset bit)
         (truncate index 8)
       (setf (ldb (byte 1 bit)
                  (ldb (byte 1 0)
                       (%array-like-ref-unsigned-byte-8 array offset)))
             value)))
    (#.+array-type-signed-byte-2+
     (check-type value (signed-byte 2))
     (multiple-value-bind (offset bit)
         (truncate index 4)
       (setf (ldb (byte 2 bit)
                  (ldb (byte 2 0)
                       (%array-like-ref-unsigned-byte-8 array offset)))
             value)))
    (#.+array-type-signed-byte-4+
     (check-type value (signed-byte 4))
     (multiple-value-bind (offset bit)
         (truncate index 2)
       (setf (ldb (byte 4 bit)
                  (ldb (byte 4 0)
                       (%array-like-ref-unsigned-byte-8 array offset)))
             value)))
    (#.+array-type-signed-byte-8+
     (setf (%array-like-ref-signed-byte-8 array index)
           value))
    (#.+array-type-signed-byte-16+
     (setf (%array-like-ref-signed-byte-16 array index)
           value))
    (#.+array-type-signed-byte-32+
     (setf (%array-like-ref-signed-byte-32 array index)
           value))
    (#.+array-type-signed-byte-64+
     (setf (%array-like-ref-signed-byte-64 array index)
           value))
    (#.+array-type-single-float+
     (check-type value single-float)
     (setf (%array-like-ref-unsigned-byte-32 array index)
           (%single-float-as-integer value)))))

(defun %memory-aref (type address index)
  (cond
    ((equal type '(unsigned-byte 8))
     (memref-unsigned-byte-8 address index))
    ((equal type '(unsigned-byte 16))
     (memref-unsigned-byte-16 address index))
    ((equal type '(unsigned-byte 32))
     (memref-unsigned-byte-32 address index))
    ((equal type '(unsigned-byte 64))
     (memref-unsigned-byte-64 address index))
    ((equal type 'base-char)
     (code-char (memref-unsigned-byte-8 address index)))
    (t (error "TODO: %MEMORY-AREF ~S." type))))

(defun (setf %memory-aref) (value type address index)
  (cond
    ((equal type '(unsigned-byte 8))
     (setf (memref-unsigned-byte-8 address index) value))
    ((equal type '(unsigned-byte 16))
     (setf (memref-unsigned-byte-16 address index) value))
    ((equal type '(unsigned-byte 32))
     (setf (memref-unsigned-byte-32 address index) value))
    ((equal type '(unsigned-byte 64))
     (setf (memref-unsigned-byte-64 address index) value))
    ((equal type 'base-char)
     (setf (memref-unsigned-byte-8 address index) (char-int value)))
    (t (error "TODO: SETF %MEMORY-AREF ~S." type))))

(defparameter *array-types*
  #(t
    base-char
    character
    bit
    (unsigned-byte 2)
    (unsigned-byte 4)
    (unsigned-byte 8)
    (unsigned-byte 16)
    (unsigned-byte 32)
    (unsigned-byte 64)
    (signed-byte 1)
    (signed-byte 2)
    (signed-byte 4)
    (signed-byte 8)
    (signed-byte 16)
    (signed-byte 32)
    (signed-byte 64)
    single-float
    double-float
    long-float
    xmm-vector
    (complex single-float)
    (complex double-float)
    (complex long-float)))

(defun %simple-array-element-type (array)
  (svref *array-types* (%simple-array-type array)))

(defun simple-string-p (object)
  (when (%simple-array-p object)
    (let ((tag (%simple-array-type object)))
      (or (eql tag +array-type-base-char+) (eql tag +array-type-character+)))))

;;; (destination source count)
(define-lap-function %fast-copy ()
  (sys.lap-x86:mov64 :rdi :r8)
  (sys.lap-x86:mov64 :rsi :r9)
  (sys.lap-x86:mov64 :rdx :r10)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:sar64 :rsi 3)
  (sys.lap-x86:sar64 :rdx 3)
  (sys.lap-x86:mov64 :rcx :rdx)
  (sys.lap-x86:sar64 :rcx 3)
  (sys.lap-x86:rep)
  (sys.lap-x86:movs64)
  (sys.lap-x86:mov32 :ecx :edx)
  (sys.lap-x86:and32 :ecx 7)
  (sys.lap-x86:rep)
  (sys.lap-x86:movs8)
  (sys.lap-x86:ret))

;; (to-storage from-storage bytes-per-col to-stride from-stride nrows)
(define-lap-function %%bitblt ()
  (sys.lap-x86:mov64 :rdi :r8) ; to-storage
  (sys.lap-x86:mov64 :rsi :r9) ; from-storage
  (sys.lap-x86:sar64 :rsi 3)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:mov64 :r8 (:rsp 8)) ; nrows
  (sys.lap-x86:sub64 :r11 :r10)
  (sys.lap-x86:sub64 :r12 :r10)
  (sys.lap-x86:jmp loop-test)
  loop-head
  (sys.lap-x86:mov64 :rcx :r10) ; bytes-per-col
  (sys.lap-x86:sar64 :rcx 6)
  (sys.lap-x86:rep)
  (sys.lap-x86:movs64)
  (sys.lap-x86:mov64 :rcx :r10) ; bytes-per-col
  (sys.lap-x86:sar32 :ecx 3)
  (sys.lap-x86:and32 :ecx 7)
  (sys.lap-x86:rep)
  (sys.lap-x86:movs8)
  (sys.lap-x86:mov64 :rax :r11) ; to-stride
  (sys.lap-x86:sar64 :rax 3)
  (sys.lap-x86:add64 :rdi :rax)
  (sys.lap-x86:mov64 :rax :r12) ; from-stride
  (sys.lap-x86:sar64 :rax 3)
  (sys.lap-x86:add64 :rsi :rax)
  loop-test
  (sys.lap-x86:sub64 :r8 8)
  (sys.lap-x86:jge loop-head)
  (sys.lap-x86:mov32 :ecx 0)
  (sys.lap-x86:mov64 :r8 nil)
  (sys.lap-x86:ret))

(defun %bitblt (nrows ncols from-array from-row from-col to-array to-row to-col)
  (let ((to-offset 0)
        (from-offset 0))
    (when (integerp (%array-header-info to-array))
      (setf to-offset (%array-header-info to-array)
            to-array (%array-header-storage to-array)))
    (when (integerp (%array-header-info from-array))
      (setf from-offset (%array-header-info from-array)
            from-array (%array-header-storage from-array)))
    (let* ((to-storage (%array-header-storage to-array))
           (from-storage (%array-header-storage from-array))
           (to-width (array-dimension to-array 1))
           (from-width (array-dimension from-array 1))
           (type (array-element-type to-array))
           (stride (cond
                     ((equal type '(unsigned-byte 8)) 1)
                     ((equal type '(unsigned-byte 16)) 2)
                     ((equal type '(unsigned-byte 32)) 4)
                     ((equal type '(unsigned-byte 64)) 8)
                     (t (error "Unsupported array type."))))
           (to-stride (* to-width stride))
           (from-stride (* from-width stride))
           (bytes-per-col (* ncols stride)))
      (assert (equal (array-element-type from-array) type))
      (unless (integerp to-storage)
        (setf to-storage (+ (lisp-object-address to-storage) 1)))
      (unless (integerp from-storage)
        (setf from-storage (+ (lisp-object-address from-storage) 1)))
      (incf to-storage (* (+ (* to-row to-width) to-col to-offset) stride))
      (incf from-storage (* (+ (* from-row from-width) from-col from-offset) stride))
      (%%bitblt to-storage from-storage bytes-per-col to-stride from-stride nrows))))

;;; (value destination count)
(define-lap-function %fast-set-8 ()
  (sys.lap-x86:mov64 :rax :r8)
  (sys.lap-x86:mov64 :rdi :r9)
  (sys.lap-x86:mov64 :rcx :r10)
  (sys.lap-x86:sar64 :rax 3)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:sar64 :rcx 3)
  (sys.lap-x86:rep)
  (sys.lap-x86:stos8)
  (sys.lap-x86:ret))

(define-lap-function %fast-set-16 ()
  (sys.lap-x86:mov64 :rax :r8)
  (sys.lap-x86:mov64 :rdi :r9)
  (sys.lap-x86:mov64 :rcx :r10)
  (sys.lap-x86:sar64 :rax 3)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:sar64 :rcx 3)
  (sys.lap-x86:rep)
  (sys.lap-x86:stos16)
  (sys.lap-x86:ret))

(define-lap-function %fast-set-32 ()
  (sys.lap-x86:mov64 :rax :r8)
  (sys.lap-x86:mov64 :rdi :r9)
  (sys.lap-x86:mov64 :rcx :r10)
  (sys.lap-x86:sar64 :rax 3)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:sar64 :rcx 3)
  (sys.lap-x86:rep)
  (sys.lap-x86:stos32)
  (sys.lap-x86:ret))

(define-lap-function %fast-set-64 ()
  (sys.lap-x86:test64 :r8 7)
  (sys.lap-x86:jnz load-bignum)
  (sys.lap-x86:mov64 :rax :r8)
  (sys.lap-x86:sar64 :rax 3)
  blah
  (sys.lap-x86:mov64 :rdi :r9)
  (sys.lap-x86:mov64 :rcx :r10)
  (sys.lap-x86:sar64 :rdi 3)
  (sys.lap-x86:sar64 :rcx 3)
  (sys.lap-x86:rep)
  (sys.lap-x86:stos64)
  (sys.lap-x86:ret)
  load-bignum
  (sys.lap-x86:mov64 :rax (:r8 #.(+ (- +tag-array-like+) 8)))
  (sys.lap-x86:jmp blah))

(defun %bitset (nrows ncols val to-array to-row to-col)
  (let ((to-displacement 0))
    (when (integerp (%array-header-info to-array))
      (setf to-displacement (%array-header-info to-array)
            to-array (%array-header-storage to-array)))
    (let* ((to-storage (%array-header-storage to-array))
           (to-width (array-dimension to-array 1))
           (to-offset (+ (* to-row to-width) to-col))
           (type (array-element-type to-array)))
      (unless (fixnump to-storage)
        (setf to-storage (+ (lisp-object-address to-storage) 1)))
      (incf to-storage (* to-displacement 4))
      (cond
        ((equal type '(unsigned-byte 8))
         (check-type val (unsigned-byte 8))
         (incf to-storage to-offset)
         (dotimes (i nrows)
           (%fast-set-8 val to-storage ncols)
           (incf to-storage to-width)))
        ((equal type '(unsigned-byte 16))
         (check-type val (unsigned-byte 16))
         (incf to-storage (* to-offset 2))
         (dotimes (i nrows)
           (%fast-set-16 val to-storage ncols)
           (incf to-storage (* to-width 2))))
        ((equal type '(unsigned-byte 32))
         (check-type val (unsigned-byte 32))
         (incf to-storage (* to-offset 4))
         (dotimes (i nrows)
           (%fast-set-32 val to-storage ncols)
           (incf to-storage (* to-width 4))))
        ((equal type '(unsigned-byte 64))
         (incf to-storage (* to-offset 8))
         (dotimes (i nrows)
           (%fast-set-64 val to-storage ncols)
           (incf to-storage (* to-width 8))))))))
