#lang racket/base
;; XXX copied from portaudio
(require ffi/vector
         ffi/unsafe
         (only-in '#%foreign ffi-callback)
         (rename-in racket/contract [-> c->])
         portaudio/portaudio
         portaudio/callback-support
         portaudio/devices
         racket/bool
         rackunit
         rackunit/text-ui
         racket/math)

;; this module provides a function that plays a sound.

(define nat? exact-nonnegative-integer?)

(provide/contract [s16vec-play (c-> s16vector? nat? (or/c false? nat?) integer?
                                    (c-> void?))])

;; it would use less memory to use stream-play, but
;; there's an unacceptable 1/2-second lag in starting
;; a new place.

(define channels 2)
(define reasonable-latency 0.1)

;; given an s16vec, a starting frame, a stopping frame or
;; false, and a sample rate, play the sound.
(define (s16vec-play s16vec start-frame pre-stop-frame sample-rate)
  (define total-frames (/ (s16vector-length s16vec) channels))
  (define stop-frame (or pre-stop-frame
                         total-frames))
  (check-args s16vec total-frames start-frame stop-frame)
  (define sound-frames (- stop-frame start-frame))
  (pa-maybe-initialize)
  (define copying-info (make-copying-info s16vec start-frame stop-frame))
  (define sr/i (exact->inexact sample-rate))
  (define device-number (find-output-device reasonable-latency))
  (define device-latency (device-low-output-latency device-number))
  (define output-stream-parameters
    (make-pa-stream-parameters
     device-number ;; device
     2             ;; channels
     '(paInt16)    ;; sample format
     device-latency ;; latency
     #f))            ;; host-specific info
  (define stream
    (with-handlers ([(lambda (exn)
                       (string=? (exn-message exn)
                                 "pa-open-stream: invalid device"))
                     (lambda (exn)
                       (error "open-stream failed with error message: ~s. See documentation for possible fixes."))])
      (pa-open-stream
       #f            ;; input parameters
       output-stream-parameters
       sr/i
       0             ;; frames-per-buffer
       '()           ;; stream-flags
       copying-callback
       copying-info)))
  (pa-set-stream-finished-callback
   stream
   copying-info-free)
  (pa-start-stream stream)
  (define (stopper)
    (pa-close-stream stream)
    (void))

  ;; this is the "worse is better" solution to closing streams;
  ;; polling is bad, but callbacks from C into Racket seem really
  ;; fragile, and the polling here can afford to be quite coarse.
  ;; the danger of not polling enough is that too many streams
  ;; will be open, and that the system will start rejecting open-stream
  ;; calls. As of 2013, Ubuntu seems to support 32 streams, and OS X
  ;; an unbounded number. What about Windows? Dunno, let's go check.
  (define sound-seconds (/ sound-frames sample-rate))
  (define expected-startup-latency 0.02)
  (define fail-wait 0.5)
  (thread
   (lambda ()
     ;; hopefully this is long enough for the sound to finish:
     (sleep (+ expected-startup-latency sound-seconds))
     (let loop ()
       (cond [(stream-already-closed? stream)
              ;; nothing to be done
              #f]
             [(not (pa-stream-active? stream))
              ;; inactive, close it:
              (pa-close-stream stream)]
             [else
              ;; wait and try again:
              (begin (sleep fail-wait)
                     (loop))]))))
  stopper)

(define (check-args vec total-frames start-frame stop-frame)
  (unless (integer? total-frames)
    (raise-type-error 's16vec-play "vector of length divisible by 2" 0 vec start-frame stop-frame))
  (when (<= total-frames start-frame)
    (raise-type-error 's16vec-play "start frame < total number of frames" 1 vec start-frame stop-frame))
  (when (< total-frames stop-frame)
    (raise-type-error 's16vec-play "end frame < total number of frames" 2 vec start-frame stop-frame))
  (when (< stop-frame start-frame)
    (raise-type-error 's16vec-play "start frame <= end frame" 1 vec start-frame stop-frame)))

(run-tests
 (test-suite "s16vec-play"
             (let ()

               (define v (make-s16vector (* channels 22055)))
               (for ([i (in-range 10000)])
                 (define sample (inexact->exact (round (* 32767 (* 0.2 (sin (* (/ 1 44100) pi 2 i 302)))))))
                 (s16vector-set! v (* i channels) sample)
                 (s16vector-set! v (add1 (* i channels)) sample))
               (for ([i (in-range 10000 22055)])
                 (define sample (inexact->exact (round (* 32767 (* 0.2 (sin (* (/ 1 44100) pi 2 i 500)))))))
                 (s16vector-set! v (* i channels) sample)
                 (s16vector-set! v (add1 (* i channels)) sample))

               ;; using the stopper while the sound is playing, no error on the cleanup thread please...
               (printf "using the stopper while the sound is playing, no error on the cleanup thread please...\n")
               (printf "start...\n")
               (define stopper (s16vec-play v 0 #f 44100))
               (stopper)
               (sleep 3)
               (printf "...stop.\n")

               (printf "1/2-second tone at 302/500 Hz\n")
               (sleep 2)
               (printf "start...\n")
               (s16vec-play v 0 #f 44100)
               (check-not-exn (lambda () (s16vec-play v 0 #f 44100)))
               (sleep 0.5)
               (printf "...stop.\n")
               (sleep 1)
               (printf "1/2-second tone at 302/500 Hz using explicit boundaries\n")
               (sleep 2)
               (printf "start...\n")
               (check-not-exn (lambda () (s16vec-play v 0 22055 44100)))
               (sleep 0.5)
               (printf "...stop.\n")
               (sleep 1)
               (printf "1/4-second tone at 302/500 Hz using offsets\n")
               (sleep 2)
               (printf "start...\n")
               (check-not-exn (lambda () (s16vec-play v 7500 20000 44100)))
               (sleep 0.5)
               (printf "...stop.\n")
               (sleep 1)
               (check-exn exn:fail?
                          (lambda ()
                            (s16vec-play v -3 20000 44100)))
               (check-exn exn:fail?
                          (lambda ()
                            (s16vec-play v 0 40000 44100)))
               (check-exn exn:fail?
                          (lambda ()
                            (s16vec-play v 10000 0 44100)))
               ;; simultaneous play:
               (printf "check whether closes are happening:\n")
               (for ([i (in-range 100)])
                 (check-not-exn (lambda () (s16vec-play v 0 4410 44100)))
                 (sleep 0.1))

               (printf "10 near-simultaneous copies of the sound")
               (sleep 2)
               (printf "start...\n")
               (for ([i (in-range 10)])
                 (check-not-exn (lambda () (s16vec-play v 0 #f 44100)))
                 (sleep 0.03))
               (sleep 0.5)
               (printf "...stop.\n")


               )))
