;; MCL backend for USOCKET 0.4.1
;; Terje Norderhaug <terje@in-progress.com>, January 1, 2009

(in-package :usocket)

(defun handle-condition (condition &optional socket)
  ; incomplete, needs to handle additional conditions
  (flet ((raise-error (&optional socket-condition)
           (error (or socket-condition 'unknown-error) :socket socket :real-error condition)))
    (typecase condition
      (ccl:host-stopped-responding
       (raise-error 'host-down-error))
      (ccl:host-not-responding
       (raise-error 'host-unreachable-error))
      (ccl:connection-reset 
       (raise-error 'connection-reset-error))
      (ccl:connection-timed-out
       (raise-error 'timeout-error))
      (ccl:opentransport-protocol-error
       (raise-error ''protocol-not-supported-error))       
      (otherwise
       (raise-error)))))

(defun socket-connect (host port &key (element-type 'character) timeout deadline nodelay 
                            local-host local-port)
  (let* ((socket
          (make-instance 'active-socket
                         :remote-host (when host (host-to-hostname host)) 
                         :remote-port port
                         :local-host (when local-host (host-to-hostname local-host)) 
                         :local-port local-port
                         :deadline deadline
                         :nodelay nodelay
                         :connect-timeout (and timeout (round (* timeout 60)))
                         :element-type element-type))
         (stream (socket-open-stream socket)))
    (make-stream-socket :socket socket :stream stream)))

(defun socket-listen (host port
                           &key reuseaddress
                           (reuse-address nil reuse-address-supplied-p)
                           (backlog 5)
                           (element-type 'character))
  (declare (ignore reuseaddress reuse-address-supplied-p))
  (let ((socket (make-instance 'passive-socket 
                  :local-port port
                  :local-host host
                  :reuse-address reuse-address
                  :backlog backlog)))
    (make-stream-server-socket socket :element-type element-type)))

(defmethod socket-accept ((usocket stream-server-usocket) &key element-type)
  (let* ((socket (socket usocket))
         (stream (socket-accept socket :element-type element-type)))
    (make-stream-socket :socket socket :stream stream)))

(defmethod socket-close ((usocket usocket))
  (with-mapped-conditions (usocket)
    (socket-close (socket usocket))))

(defmethod ccl::stream-close ((usocket usocket))
  (socket-close usocket))

(defun get-hosts-by-name (name)
  (with-mapped-conditions ()
    (list (hbo-to-vector-quad (ccl::get-host-address
                               (host-to-hostname name))))))

(defun get-host-by-address (address)
  (with-mapped-conditions ()
    (ccl::inet-host-name (host-to-hbo address))))

(defmethod get-local-name ((usocket usocket))
  (values (get-local-address usocket)
          (get-local-port usocket)))

(defmethod get-peer-name ((usocket stream-usocket))
  (values (get-peer-address usocket)
          (get-peer-port usocket)))

(defmethod get-local-address ((usocket usocket))
  (hbo-to-vector-quad (ccl::get-host-address (or (local-host (socket usocket)) ""))))

(defmethod get-local-port ((usocket usocket))
  (local-port (socket usocket)))

(defmethod get-peer-address ((usocket stream-usocket))
  (hbo-to-vector-quad (ccl::get-host-address (remote-host (socket usocket)))))

(defmethod get-peer-port ((usocket stream-usocket))
  (remote-port (socket usocket)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; BASIC MCL SOCKET IMPLEMENTATION

(require :opentransport)

(defclass socket ()
  ((local-port :reader local-port :initarg :local-port)
   (local-host :reader local-host :initarg :local-host)
   (element-type :reader element-type :initform 'ccl::base-character :initarg :element-type)))

(defclass active-socket (socket)
  ((remote-host :reader remote-host :initarg :remote-host)
   (remote-port :reader remote-port :initarg :remote-port)
   (deadline :initarg :deadline)
   (nodelay :initarg :nodelay)
   (connect-timeout :reader connect-timeout :initform NIL :initarg :connect-timeout
                    :type (or null fixnum) :documentation "ticks (60th of a second)")))

(defmethod socket-open-stream ((socket active-socket))
  (ccl::open-tcp-stream (or (remote-host socket)(ccl::local-interface-ip-address)) (remote-port socket)
   :element-type (if (subtypep (element-type socket) 'character) 'ccl::base-character 'unsigned-byte)
   :connect-timeout (connect-timeout socket)))

(defmethod socket-close ((socket active-socket))
  NIL)

(defclass passive-socket (socket)
  ((streams :accessor socket-streams :type list :initform NIL
            :documentation "Circular list of streams with first element the next to open")
   (reuse-address :reader reuse-address :initarg :reuse-address)))

(defmethod initialize-instance :after ((socket passive-socket) &key backlog)
  (loop repeat backlog
        collect (socket-open-listener socket) into streams
        finally (setf (socket-streams socket)
                      (cdr (rplacd (last streams) streams))))
  (when (zerop (local-port socket))
    (setf (slot-value socket 'local-port)
          (or (ccl::process-wait-with-timeout "binding port" (* 10 60) 
               #'ccl::stream-local-port (car (socket-streams socket)))
              (error "timeout")))))

(defmethod socket-accept ((socket passive-socket) &key element-type)
  (flet ((connection-established-p (stream) 
           (ccl::with-io-buffer-locked ((ccl::stream-io-buffer stream nil)) 
             (let ((state (ccl::opentransport-stream-connection-state stream)))
               (not (eq :unbnd state))))))
    (with-mapped-conditions ()
      (let* ((new (socket-open-listener socket element-type))
             (connection (car (socket-streams socket))))
        (assert connection)
        (rplaca (socket-streams socket) new)
        (setf (socket-streams socket) 
              (cdr (socket-streams socket)))
        (ccl::process-wait "Socket Accept" #'connection-established-p connection) ; expensive polling...
        connection))))

(defmethod socket-close ((socket passive-socket))
  (loop
    with streams = (socket-streams socket)
    for (stream tail) on streams
    do (close stream :abort T)
    until (eq tail streams)
    finally (setf (socket-streams socket) NIL)))

(defmethod socket-open-listener (socket &optional element-type)
  ; see http://code.google.com/p/mcl/issues/detail?id=28
  (let* ((ccl::*passive-interface-address* (local-host socket))
         (new (ccl::open-tcp-stream NIL (or (local-port socket) #$kOTAnyInetAddress) 
                                    :reuse-local-port-p (reuse-address socket) 
                                    :element-type (if (subtypep (or element-type (element-type socket))
                                                                'character) 
                                                    'ccl::base-character 
                                                    'unsigned-byte))))
    (declare (special ccl::*passive-interface-address*))
    new))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
#| TEST (from test-usocket.lisp)


(defparameter +non-existing-host+ "192.168.1.1")
(defparameter +unused-local-port+ 15213)
(defparameter *soc1* (usocket::make-stream-socket :socket :my-socket
                                                  :stream :my-stream))
(defparameter +common-lisp-net+ #(208 72 159 207)) ;; common-lisp.net IP


(usocket:socket *soc1*)

(usocket:socket-connect "127.0.0.0" +unused-local-port+)

(usocket:socket-connect #(127 0 0 0) +unused-local-port+)

(usocket:socket-connect 2130706432 +unused-local-port+)

    (let ((sock (usocket:socket-connect "common-lisp.net" 80)))
      (unwind-protect
          (typep sock 'usocket:usocket)
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect +common-lisp-net+ 80)))
      (unwind-protect
          (typep sock 'usocket:usocket)
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect (usocket::host-byte-order +common-lisp-net+) 80)))
      (unwind-protect
          (typep sock 'usocket:usocket)
        (usocket:socket-close sock)))

(let ((sock (usocket:socket-connect "common-lisp.net" 80)))
      (unwind-protect
          (progn
            (format (usocket:socket-stream sock)
                    "GET / HTTP/1.0~A~A~A~A"
                    #\Return #\Linefeed #\Return #\Linefeed)
            (force-output (usocket:socket-stream sock))
            (read-line (usocket:socket-stream sock)))
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect +common-lisp-net+ 80)))
      (unwind-protect
          (usocket::get-peer-address sock)
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect +common-lisp-net+ 80)))
      (unwind-protect
          (usocket::get-peer-port sock)
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect +common-lisp-net+ 80)))
      (unwind-protect
          (usocket::get-peer-name sock)
        (usocket:socket-close sock)))

    (let ((sock (usocket:socket-connect +common-lisp-net+ 80)))
      (unwind-protect
          (usocket::get-local-address sock)
        (usocket:socket-close sock)))

|#


#|

(defun socket-server (host port)
  (let ((socket (socket-listen host port)))
    (unwind-protect
      (loop
        (with-open-stream (stream (socket-stream (socket-accept socket))) 
          (ccl::telnet-write-line stream "~A" 
           (reverse (ccl::telnet-read-line stream)))
          (ccl::force-output stream)))
      (close socket))))

(ccl::process-run-function "Socket Server" #'socket-server NIL 4088)

(let* ((sock (socket-connect nil 4088))
       (stream (usocket:socket-stream sock)))
  (assert (streamp stream))
  (ccl::telnet-write-line stream "hello ~A" (random 10))
  (ccl::force-output stream)
  (ccl::telnet-read-line stream))

|#