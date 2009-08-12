;;;; -*- coding: utf-8; indent-tabs-mode: nil -*-

(defpackage #:perfpiece
    (:use #:cl #:cffi)
  (:import-from #:alexandria
                #:make-keyword #:switch #:when-let #:with-unique-names
                #:symbolicate #:mean #:standard-deviation #:once-only))
(in-package #:perfpiece)

;;;; Errors

(define-condition perfpiece-error (simple-error) ())
(define-condition papi-error (perfpiece-error) ())

(defmacro define-papi-error-codes (&body pairs)
  (let ((condition-names (loop for pair in pairs collect
                               (symbolicate '#:papi- (car pair)))))
    `(progn
       ,@(loop for name in condition-names collect
               `(define-condition ,name (papi-error) ()))
       (defun papi-error-string (error-code)
         (ecase error-code
           ,@(loop for code downfrom -1 and p in pairs collect
             (list code (format nil (second p))))))
       (defun papi-error-condition (error-code)
         (ecase error-code
           ,@(loop for code downfrom -1 and condition in condition-names
                   collect `(,code ',condition)))))))

(define-papi-error-codes
  (einval "Invalid argument")
  (enomem "Insufficient memory")
  (esys "A System/C library call failed, please check errno")
  (esbstr "Substrate returned an error, usually the result of an ~
           unimplemented feature")
  (enosupp "ENOSUPP")
  (eclost "Access to the counters was lost or interrupted")
  (ebug "Internal error, please send mail to the developers")
  (enoevnt "Hardware Event does not exist")
  (ecnflct "Hardware Event exists, but cannot be counted due to counter ~
            resource limitations")
  (enotrun "No Events or EventSets are currently counting")
  (eisrun "Events or EventSets are currently counting")
  (enoevst "No EventSet available")
  (enotpreset "Not a Present Event in argument")
  (enocntr "Hardware does not support counters")
  (emisc "No clue as to what this error code means")
  (eperm "You lack the necessary permissions")
  (enoinit "PAPI hasn't been initialized yet")
  (ebuf "Buffer size exceeded (usually strings)"))

(defun perfpiece-error (message &rest args)
  (error 'perfpiece-error :format-control message :format-arguments args))

(defun papi-error (code)
  (error (papi-error-condition code) :format-control "~A"
         :format-arguments (list (papi-error-string code))))

(define-foreign-type papi-error-code ()
  ()
  (:simple-parser papi-error-code)
  (:actual-type :int))

(defmethod expand-from-foreign (value (type papi-error-code))
  (with-unique-names (return-code)
    `(let ((,return-code ,value))
       (if (minusp ,return-code)
           (papi-error ,return-code)
           ,return-code))))

;;;; Initialization

(defconstant +papi-not-inited+ 0)

(defcfun "PAPI_is_initialized" :int)

(defun papi-initialized-p ()
  (not (eql (papi-is-initialized) +papi-not-inited+)))

;;; In addition to its usual role, we use this function to initialize
;;; the library.
(defcfun "PAPI_num_counters" papi-error-code)

(defun initialize-papi-if-necessary ()
  (unless (papi-initialized-p)
    (papi-num-counters)
    t))

;;;; Listing and Querying Events

(defclass event ()
  ((name :reader event-name :initarg :name)
   (code :reader event-code :initarg :code)
   (short-description :reader event-short-description
                      :initarg :short-description)
   (description :reader event-description :initarg :description)
   (derived :reader event-derived :initarg :derived)
   (note :reader event-note :initarg :note)
   (availablep :reader event-availablep :initarg :available)
   (nativep :reader event-nativep :initarg :native)
   (papip :reader papi-event-p :initarg :papi)))

(defmethod print-object ((event event) stream)
  (print-unreadable-object (event stream :type t)
    (with-slots (name short-description nativep) event
      (format stream "~S~@[ ~S~]~@[ (native)~]"
              name short-description nativep))))

(defconstant +papi-min-str-len+ 64)
(defconstant +papi-max-str-len+ 128)
(defconstant +papi-2max-str-len+ 256)
(defconstant +papi-huge-str-len+ 1024)
(defconstant +papi-max-info-terms+ 12)

(defcstruct event-info
  (event-code :uint)
  (event-type :uint)
  (count :uint)
  (symbol :char :count #.+papi-huge-str-len+)
  (short-descr :char :count #.+papi-min-str-len+)
  (long-descr :char :count #.+papi-huge-str-len+)
  (derived :char :count #.+papi-min-str-len+)
  (postfix :char :count #.+papi-min-str-len+)
  (code :uint :count #.+papi-max-info-terms+)
  (name :char :count #.(* +papi-max-info-terms+ +papi-2max-str-len+))
  (note :char :count #.+papi-huge-str-len+))

(defcfun "PAPI_get_event_info" papi-error-code
  (event-code :uint)
  (info event-info))

(defun cstring (pointer)
  (let ((string (foreign-string-to-lisp pointer :encoding :ascii :errorp nil)))
    (if (zerop (length string))
        nil
        string)))

(defconstant +first-native-event-code+ #x40000000)
(defconstant +first-preset-event-code+ #x80000000)

(defun native-code-p (code)
  (<= +first-native-event-code+ code (1- +first-preset-event-code+)))

(defun papi-code-to-event (code info)
  (when (zerop (papi-get-event-info code info))
    (with-foreign-slots ((count symbol short-descr long-descr derived note)
                         info event-info)
      (make-instance
       'event
       :name (make-keyword (substitute #\- #\_ (cstring symbol)))
       :code code
       :short-description (cstring short-descr)
       :description (cstring long-descr)
       :derived (when-let ((string (cstring derived)))
                  (switch (string :test 'string=)
                    ("NOT_DERIVED" nil)
                    ("DERIVED_SUB" :sub)
                    ("DERIVED_ADD" :add)
                    ("DERIVED_POSTFIX" :postfix)
                    (t (make-keyword (substitute #\= #\_ string)))))
       :note (cstring note)
       :available (plusp count)
       :native (native-code-p code)
       :papi t))))

(defcfun "PAPI_enum_event" papi-error-code
  (event-code (:pointer :uint))
  (modifier :int))

(defun push-events-to-hash-table (info first-event-code hash-table)
  (with-foreign-object (code :uint)
    (setf (mem-ref code :uint) first-event-code)
    (loop for event = (papi-code-to-event (mem-ref code :uint) info)
          do (setf (gethash (event-name event) hash-table) event)
          while (zerop (papi-enum-event code 0)))))

(defun push-all-events-to-hash-table (hash-table)
  (initialize-papi-if-necessary)
  (with-foreign-object (info 'event-info)
    (push-events-to-hash-table info +first-preset-event-code+ hash-table)
    (push-events-to-hash-table info +first-native-event-code+ hash-table)))

(defvar *events* (make-hash-table))

(defmacro define-event (name description)
  `(setf (gethash ,name *events*)
         (make-instance 'event
                        :name ,name
                        :short-description ,description
                        :description ,description
                        :native nil
                        :papi nil)))

;;; For some reason, PAPI really only likes to be loaded once.
(when (zerop (hash-table-count *events*))
  (load-foreign-library '(:or "libpapi.so.3" "libpapi.so"))
  (push-all-events-to-hash-table *events*))

(defun list-event-names ()
  (loop for event being the hash-keys of *events* collect event))

(defun list-available-event-names ()
  (loop for name being the hash-keys of *events*
        and event being the hash-values of *events*
        when (event-availablep event)
        collect name))

(defun find-event (name)
  (values (gethash name *events*)))

(defun find-event-or-lose (name)
  (or (find-event name) (perfpiece-error "no such event ~S" name)))

;;;; Event Sets

(declaim (inline papi-start papi-stop papi-accum papi-write))

(defcfun "PAPI_start" papi-error-code
  (event-set :int))

(defcfun "PAPI_stop" papi-error-code
  (event-set :int)
  (values (:pointer :long-long)))

(defcfun "PAPI_read" papi-error-code
  (event-set :int)
  (values (:pointer :long-long)))

(defcfun "PAPI_write" papi-error-code
  (event-set :int)
  (values (:pointer :long-long)))

(defcfun "PAPI_accum" papi-error-code
  (event-set :int)
  (values (:pointer :long-long)))

(defcfun "PAPI_reset" papi-error-code
  (event-set :int))

(defclass event-set ()
  ((handle :accessor handle-of :initarg :handle)
   (events :accessor events-of :initarg :events)
   (sw-events :accessor sw-events-of :initarg :sw-events)
   (gc-values :accessor gc-values-of :initarg :gc-values)
   (mutator-values :accessor mutator-values-of :initarg :mutator-values)))

(defmethod print-object ((set event-set) stream)
  (print-unreadable-object (set stream :type t :identity t)
    (format stream "~{~A~^ ~}" (mapcar #'event-name (events-of set)))))

(defconstant +papi-null+ -1)

(defcfun "PAPI_create_eventset" papi-error-code
  (event-set (:pointer :int)))

(defcfun "PAPI_add_event" papi-error-code
  (event-set :int)
  (event-code :uint))

(defun make-counter-array (count)
  (foreign-alloc :long-long :count count :initial-element 0))

(defun make-event-set (event-names)
  (let* ((events (mapcar #'find-event-or-lose event-names))
         (papi-events (remove-if-not #'papi-event-p events))
         (count (length papi-events)))
    (with-foreign-object (handle-ptr :int)
      (setf (mem-ref handle-ptr :int) +papi-null+)
      (papi-create-eventset handle-ptr)
      (let ((handle (mem-ref handle-ptr :int)))
        (dolist (event papi-events)
          ;; TODO: handle errors.
          (papi-add-event handle (event-code event)))
        (make-instance 'event-set
                       :handle handle
                       :events papi-events
                       :sw-events (remove-if #'papi-event-p events)
                       :gc-values (make-counter-array count)
                       :mutator-values (make-counter-array count))))))

(defun reset-event-set (set)
  (flet ((clear-counter-array (array)
           (loop for i below (length (events-of set))
                 do (setf (mem-aref array :long-long i) 0))))
    (clear-counter-array (gc-values-of set))
    (clear-counter-array (mutator-values-of set)))
  (papi-reset (handle-of set)))

(defcfun "PAPI_cleanup_eventset" papi-error-code
  (event-set :int))

(defcfun "PAPI_destroy_eventset" papi-error-code
  (event-set (:pointer :int)))

(defcfun ("PAPI_state" %papi-state) papi-error-code
  (event-set :int)
  (status (:pointer :int)))

(defconstant +papi-stopped+ 1)

(defun papi-state (handle)
  (with-foreign-object (status :int)
    (%papi-state handle status)
    (mem-ref status :int)))

(defun destroy-event-set (set)
  (unless (eql (logand +papi-stopped+ (papi-state (handle-of set)))
               +papi-stopped+)
    (papi-stop (handle-of set) (null-pointer)))
  (papi-cleanup-eventset (handle-of set))
  (with-foreign-object (handle-ptr :int)
    (setf (mem-ref handle-ptr :int) (handle-of set))
    (papi-destroy-eventset handle-ptr))
  (foreign-free (gc-values-of set))
  (foreign-free (mutator-values-of set))
  (setf (handle-of set) +papi-null+)
  (setf (events-of set) nil)
  (setf (gc-values-of set) (null-pointer))
  (setf (mutator-values-of set) (null-pointer))
  set)

(defmacro with-event-set-slots
    (event-set (handle-arg mutator-values-arg gc-values-arg) &body body)
  (once-only (event-set)
    `(let* ((,mutator-values-arg (mutator-values-of ,event-set))
            (,gc-values-arg (gc-values-of ,event-set))
            (,handle-arg (handle-of ,event-set)))
       (check-type ,handle-arg (signed-byte ,(* 8 (foreign-type-size :int))))
       (check-type ,mutator-values-arg foreign-pointer)
       (check-type ,gc-values-arg foreign-pointer)
       ,@body)))

(defmacro with-event-set ((name-arg events) &body body)
  `(let ((,name-arg (make-event-set ,events)))
     (unwind-protect (progn ,@body)
       (destroy-event-set ,name-arg))))

#+#:ignore
(defmacro with-event-set ((name-arg events)
                          (handle-arg mutator-values-arg gc-values-arg)
                          &body body)
  `(let* ((,name-arg (make-event-set ,events))
          (,mutator-values-arg (mutator-values-of ,name-arg))
          (,gc-values-arg (gc-values-of ,name-arg))
          (,handle-arg (handle-of ,name-arg)))
     (check-type ,handle-arg (signed-byte ,(* 8 (foreign-type-size :int))))
     (check-type ,mutator-values-arg foreign-pointer)
     (check-type ,gc-values-arg foreign-pointer)
     (unwind-protect (progn ,@body)
       (destroy-event-set ,name-arg))))

;;;; Querying the Hardware

(defconstant +papi-mh-max-levels+ 4)
(defconstant +papi-max-mem-hierarchy-levels+ +papi-mh-max-levels+)

(defcstruct papi-mh-tlb-info
  (type :int)
  (num-entries :int)
  (associativity :int))

(defcstruct papi-mh-cache-info
  (type :int)
  (size :int)
  (line-size :int)
  (num-lines :int)
  (associativity :int))

(defcstruct papi-mh-level-info
  (tlb papi-mh-tlb-info :count #.+papi-mh-max-levels+)
  (cache papi-mh-cache-info :count #.+papi-mh-max-levels+))

(defcstruct papi-mh-info
  (levels :int)
  (level papi-mh-level-info :count #.+papi-max-mem-hierarchy-levels+))

(defcstruct papi-hw-info
  (ncpu :int)
  (nnodes :int)
  (totalcpus :int)
  (vendor :int)
  (vendor-string :char :count #.+papi-max-str-len+)
  (model :int)
  (model-string :char :count #.+papi-max-str-len+)
  (revision :float)
  (mhz :float)
  (clock-mhz :int)
  (mem-hierarchy papi-mh-info))

(defcfun "PAPI_get_hardware_info" papi-hw-info)

(defun get-processor-info ()
  (with-foreign-slots ((ncpu nnodes totalcpus vendor vendor-string model
                        model-string revision mhz clock-mhz)
                       (papi-get-hardware-info) papi-hw-info)
    (list :cpus totalcpus :nodes nnodes :cpus-per-node ncpu :vendor-id vendor
          :vendor (cstring vendor-string) :model-id model
          :model (cstring model-string) :revision revision :mhz mhz
          :clock-mhz clock-mhz)))

;;; TODO: get-memory-info

(defun num-hardware-counters ()
  (papi-num-counters))

;;;; Measuring Time

(declaim (inline papi-get-real-nsec papi-get-virt-nsec))

#+#:ignore (defcfun "PAPI_get_real_usec" :long-long)
(defcfun "PAPI_get_real_nsec" :long-long)
(defcfun "PAPI_get_virt_nsec" :long-long)

(define-event :real-time "Real time")
(define-event :user-time "User time")

;;;; GC runs

(define-event :gc-count "GC count")

;;;; Measuring System Info

(defcstruct timeval
  (sec :long)
  (usec :long))

(defcstruct rusage
  (utime timeval)
  (stime timeval)
  (maxrss :long)
  (ixrss :long)
  (idrss :long)
  (isrss :long)
  (minflt :long)
  (majflt :long)
  (nswap :long)
  (inblock :long)
  (outblock :long)
  (msgsnd :long)
  (msgrcv :long)
  (nsignals :long)
  (nvcsw :long)
  (nivcsw :long))

(defconstant +rusage-self+ 0)
(defconstant +rusage-children+ -1)
(defconstant +rusage-thread+ 1)

(declaim (inline getrusage))
(defcfun "getrusage" :int
  (who :int)
  (usage rusage))

(defun get-resource-usage ()
  (with-foreign-object (rusage 'rusage)
    (getrusage +rusage-self+ rusage)
    (with-foreign-slots ((stime majflt nvcsw nivcsw) rusage rusage)
      (with-foreign-slots ((sec usec) stime timeval)
        (values (+ (* sec 1000000000) (* usec 1000))
                majflt nvcsw nivcsw)))))

(define-event :system-time "System time")

;;;; Profiling


;;;; Interface

#+sbcl
(defmacro with-instrumented-gc (before-clause after-clause &body body)
  (assert (and (eql (car before-clause) :before)
               (eql (car after-clause) :after)))
  (with-unique-names (original-sub-gc instrumented-sub-gc)
    `(let ((,original-sub-gc #'sb-kernel:sub-gc))
       (flet ((,instrumented-sub-gc (&rest args)
                ,@(cdr before-clause)
                (apply ,original-sub-gc args)
                ,@(cdr after-clause)))
         (sb-ext:without-package-locks
           (setf (fdefinition 'sb-kernel:sub-gc) #',instrumented-sub-gc)
           (unwind-protect
                (progn ,@body)
             (setf (fdefinition 'sb-kernel:sub-gc) ,original-sub-gc)))))))

#-sbcl
(defmacro with-instrumented-gc (before-clause after-clause &body body)
  (error "~S not implemented in this platform. Patches welcome."
         'call-with-instrumented-gc))

(defun %call-with-measurements (event-set function consumer)
  (check-type function function)
  (with-event-set-slots event-set (handle mutator-values gc-values)
    (let ((real-nsec-total 0)
          (tmp-real-nsec-before-gc 0)
          (real-nsec-gc 0)
          (user-nsec-total 0)
          (user-nsec-gc 0)
          (tmp-user-nsec-before-gc 0)
          return-values
          system-nsec-total
          (system-nsec-gc 0)
          tmp-system-nsec-before-gc
          (gc-count 0))
      (declare (type (signed-byte #.(* 8 (foreign-type-size :long-long)))
                     real-nsec-total user-nsec-total)
               (dynamic-extent return-values))
      (setq system-nsec-total (get-resource-usage))
      (with-instrumented-gc
          (:before (papi-accum handle mutator-values)
                   (incf gc-count)
                   (setq tmp-system-nsec-before-gc (get-resource-usage))
                   (setq tmp-real-nsec-before-gc (papi-get-real-nsec))
                   (setq tmp-user-nsec-before-gc (papi-get-virt-nsec)))
          (:after (papi-accum handle gc-values)
                  (incf real-nsec-gc
                        (- (papi-get-real-nsec) tmp-real-nsec-before-gc))
                  (incf user-nsec-gc
                        (- (papi-get-virt-nsec) tmp-user-nsec-before-gc))
                  (incf system-nsec-gc
                        (- (get-resource-usage) tmp-system-nsec-before-gc)))
        (locally (declare (optimize (speed 3) (safety 0)))
          (papi-start handle)
          (setq user-nsec-total (papi-get-virt-nsec))
          (setq real-nsec-total (papi-get-real-nsec))
          (setq return-values (multiple-value-list (funcall function)))
          (setq real-nsec-total (- (papi-get-real-nsec) real-nsec-total))
          (setq user-nsec-total (- (papi-get-virt-nsec) user-nsec-total))
          (papi-accum handle mutator-values)))
      (papi-stop handle (null-pointer))
      (setq system-nsec-total (- (get-resource-usage) system-nsec-total))
      ;; Aggregate measurements.
      (let ((hw-event-results
             (loop for event in (events-of event-set) and i from 0 collect
               (let ((mutator (mem-aref mutator-values :long-long i))
                     (gc (mem-aref gc-values :long-long i)))
                 (list event (+ mutator gc) mutator gc))))
            (sw-event-results nil))
        (flet
            ((note (event total mutator gc)
               (when (member event (sw-events-of event-set) :key #'event-name)
                 (push (list (find-event event) total mutator gc)
                       sw-event-results))))
          (note :real-time real-nsec-total
                (- real-nsec-total real-nsec-gc) real-nsec-gc)
          (note :user-time user-nsec-total
                (- user-nsec-total user-nsec-gc) user-nsec-gc)
          (note :system-time system-nsec-total
                (- system-nsec-total system-nsec-gc) system-nsec-gc)
          (note :gc-count gc-count -1 -1))
        (funcall consumer (nconc hw-event-results sw-event-results)))
      ;; Return FUNCTION's return values.
      (apply #'values return-values))))

(defun call-with-measurements (events function consumer)
  (with-event-set (set events)
    (%call-with-measurements set function consumer)))

(defun munge-sample-results (events results)
  (labels ((funcall3 (fn results)
             (list (funcall fn (mapcar #'first results))
                   (funcall fn (mapcar #'second results))
                   (funcall fn (mapcar #'third results))))
           (listify-result (event result)
             (list event
                   :min (funcall3 (lambda (list)
                                    (loop for el in list minimize el)) result)
                   :max (funcall3 (lambda (list)
                                    (loop for el in list maximize el)) result)
                   :mean (funcall3 #'mean result)
                   :stddev (funcall3 #'standard-deviation result))))
    (loop for event in events
          for result = (loop for result in results collect
                         (cdr (assoc event result :key #'event-name)))
          collect (listify-result event result))))

(defun %sample (events function samples discard-first)
  (when discard-first
    (incf samples))
  (with-event-set (set events)
    (let ((results nil))
      (loop repeat samples
            do (%call-with-measurements
                set function (lambda (res) (push res results)))
            do (reset-event-set set))
      (when discard-first
        (pop results))
      (munge-sample-results events results))))

(defun sample (events function &key (samples 10) (report :table)
               (discard-first t))
  (let ((results (%sample events function samples discard-first)))
    (ecase report
      (:table (report-results-as-table results) (values))
      ((nil) results))))

;;; I'm pretty sure FORMAT can do this on its own with ~<n>@A, but I
;;; don't have the necessary FORMAT-fu right now.
(defun print-table-line (widths values &key (pad-first-column #\.)
                         (align-first-column :left))
  (let ((padding (- (first widths)
                    (length (princ-to-string (first values)))
                    1)))
    (ecase align-first-column
      (:left
         (princ (first values))
         (princ #\Space)
         (loop repeat padding do (princ (or pad-first-column #\Space))))
      (:right
         (loop repeat padding do (princ (or pad-first-column #\Space)))
         (princ #\Space)
         (princ (first values)))))
  (loop for value in (rest values)
        for width in (rest widths)
        do (princ #\Space)
           (loop repeat (- width (length (princ-to-string value)))
                 do (princ #\Space))
           (princ value))
  (terpri))

(defun event-description-or-name (symbol-or-event max-width)
  (let ((event (etypecase symbol-or-event
                 (event symbol-or-event)
                 (symbol (find-event-or-lose symbol-or-event)))))
    (if (<= (length (event-description event)) max-width)
        (event-description event)
        (or (event-short-description event)
            (substitute #\Space #\- (symbol-name (event-name event)))))))

(defun print-horizontal-separator (widths)
  (loop repeat (+ (1- (length widths)) (reduce #'+ widths))
        do (princ #+#:ignore #\BOX_DRAWINGS_HEAVY_HORIZONTAL
                  #\BOX_DRAWINGS_LIGHT_HORIZONTAL
                  #+#:ignore #\BOX_DRAWINGS_LIGHT_QUADRUPLE_DASH_HORIZONTAL))
  (terpri))

(defun format-number (event-name n)
  (when (eql n -1)
    (return-from format-number ""))
  (case event-name
    ((:time :real-time :user-time :system-time)
       (cond ((zerop n) "0")
             ((< n 1000) (format nil "~D ns" (round n)))
             ((< n 1000000) (format nil "~,2F us" (/ n 1000)))
             ((< n 1000000000) (format nil "~,2F ms" (/ n 1000000)))
             (t (format nil "~,3F s" (/ n 1000000000)))))
    (t
       (cond ((>= n 1000000000) (format nil "~13E" n))
             ((integerp n) (format nil "~:D" n))
             (t (if (>= n 1000)
                    (format nil "~:D" (round n))
                    (format nil "~,2F" n)))))))

(defun print-data-line (ev widths legend data accessor)
  (print-table-line
   widths
   (let ((mean (funcall accessor (getf data :mean))))
     (list legend
           (format-number ev (funcall accessor (getf data :min)))
           (format-number ev (funcall accessor (getf data :max)))
           (format-number ev mean)
           (format nil "± ~6,3F%"
                   (if (zerop mean)
                       0
                       (* (/ (funcall accessor (getf data :stddev)) mean)
                          100)))))
   :align-first-column :right
   :pad-first-column #\Space))

(defun report-results-as-table (results)
  (format t "~2&")
  (let ((widths '(25 13 13 13 10)))
    (dolist (event results)
      (destructuring-bind (name &rest data) event
        (let ((desc (format nil "[~A]" (event-description-or-name name 30)))
              (adjusted-widths (copy-list widths)))
          (when (> (length desc) (first widths))
            (setf (second adjusted-widths)
                  (- (second widths) 1 (- (length desc) (first widths)))))
          (print-table-line adjusted-widths
                            (list desc "Min" "Max" "Mean" "Stddev")
                            :pad-first-column nil))
        (print-horizontal-separator widths)
        (print-data-line name widths "total:" data #'first)
        (print-data-line name widths "non-gc:" data #'second)
        (print-data-line name widths "gc-only:" data #'third))
      (terpri))))

(defun report-ascertainableness (results)
  (format t "~2&")
  (let ((widths '(30 13 13 13)))
    (print-table-line widths '("" "non-GC" "GC" "Total")
                      :pad-first-column nil)
    (print-horizontal-separator widths)
    (dolist (result results)
      (destructuring-bind (event total mutator gc) result
        (print-table-line
         widths (cons (concatenate 'string
                                   (event-description-or-name event 30) ":")
                      (mapcar (lambda (x) (format-number (event-name event) x))
                              (list mutator gc total)))
         :align-first-column :right
         :pad-first-column nil))))
  (terpri))

(defmacro ascertain (form &key (events '(:papi-tot-cyc :real-time
                                         :user-time :system-time)))
  `(call-with-measurements
    ,events (lambda () ,form) #'report-ascertainableness))