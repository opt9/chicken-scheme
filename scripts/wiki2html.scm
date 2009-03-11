;;;; wiki2html.scm - quick-and-dirty svnwiki->HTML conversion
;
; usage: wiki2html <INPUTFILE >OUTPUTFILE


(use regex srfi-1 extras utils srfi-13 posix)
(use htmlprag matchable)


;;; inline elements

(define +code+ '(: #\{ #\{ (submatch (*? any)) #\} #\}))
(define +bold+ '(: (= 3 #\') (submatch (* (~ #\'))) (= 3 #\')))
(define +italic+ '(: (= 2 #\') (submatch (* (~ #\'))) (= 2 #\')))
(define +html-tag+ '(: #\< (submatch (* (~ #\>))) #\>))

(define +link+
  '(: #\[ #\[ (? (: (* space) "image:" (* space)))
      (submatch (* (~ #\] #\|))) (? #\| (submatch (* (~ #\])))) #\] #\]))

(define +inline-element+
  `(or ,+code+ ,+link+ ,+html-tag+ ,+bold+ ,+italic+))

(define +http-url+ '(: (* space) "http://" (* any)))


;;; Block elements

(define +header+ '(: (submatch (>= 2 #\=)) (* space) (submatch (* any))))
(define +pre+ '(: (>= 1 space) (submatch (* any))))

(define +d-list+
  '(: (* space) #\; (submatch (*? any)) #\space #\: #\space (submatch (* any))))

(define +u-list+ '(: (* space) (submatch (>= 1 #\*)) (* space) (submatch (* any))))
(define +o-list+ '(: (* space) (submatch (>= 1 #\*)) #\# (* space) (submatch (* any))))
(define +hr+ '(: (* space) (submatch (>= 3 #\-)) (* space)))

(define +block-element+
  `(or ,+pre+
       ,+header+
       ,+d-list+
       ,+u-list+
       ,+o-list+
       ,+hr+))


;;; Global state

(define *tags* '())
(define *open* '())
(define *manual-pages* '())
(define *list-continuation* #f)

(define (push-tag tag out)
  ;(fprintf (current-error-port) "start: tag: ~a, open: ~a~%" tag *open*)
  (unless (and (pair? *open*) (equal? tag (car *open*)))
    (when (pair? *open*)
      (cond ((not (pair? tag)) (pop-tag out))
	    ((pair? (car *open*))
	     ;(fprintf (current-error-port) "tag: ~a, open: ~a~%" tag *open*)
	     (when (< (cdr tag) (cdar *open*))
	       (do ((n (cdar *open*) (sub1 n)))
		   ((= (cdr tag) n))
		 (pop-tag out))))))
    (unless (and (pair? *open*) (equal? tag (car *open*)))
      (fprintf out "<~a>~%" (if (pair? tag) (car tag) tag))
      (set! *list-continuation* #f)
      ;(fprintf (current-error-port) "PUSH: ~a~%" tag)
      (set! *open* (cons tag *open*)))))

(define (pop-tag out)
  (let ((tag (car *open*)))
    ;(fprintf (current-error-port) "POP: ~a~%" *open*)
    (fprintf out "</~a>~%" (if (pair? tag) (car tag) tag))
    (set! *open* (cdr *open*))))

(define (pop-all out)
  (when (pair? *open*)
    (pop-tag out)
    (pop-all out)))


;;; Helper syntax

(define-syntax rx
  (syntax-rules ()
    ((_ rx) (force (delay (regexp rx))))))


;;; Conversion entry point

(define (wiki->html #!optional (in (current-input-port)) (out (current-output-port)))
  (call/cc
   (lambda (return)
     (let loop ()
       (let ((ln (read-line in)))
	 (cond ((eof-object? ln) (return #f))
	       ((not (string-match (rx +block-element+) ln)) 
		(cond ((string-null? ln)
		       (display "<br />\n" out)
		       (set! *list-continuation* #f))
		      (else
		       (pop-all out)
		       (fprintf out "~a~%" (inline ln)))))
	       ((string-match (rx +header+) ln) =>
		(lambda (m)
		  (pop-all out)
		  (let ((n (sub1 (string-length (second m))))
			(name (clean (third m))))
		    (fprintf out "<a name='~a' /><h~a>~a</h~a>~%" 
			     name n name n))))
	       ((string-match (rx +pre+) ln) =>
		(lambda (m)
		  (cond (*list-continuation* 
			 (fprintf out "~a~%" (inline (second m))))
			(else
			 (push-tag 'pre out)
			 (fprintf out "~a~%" (clean (car m)))))))
	       ((string-match (rx +hr+) ln) =>
		(lambda (m)
		  (fprintf out "<hr />~%")))
	       ((string-match (rx +d-list+) ln) =>
		(lambda (m)
		  (push-tag 'dl out)
		  (set! *list-continuation* #t)
		  (fprintf out "<dt>~a</dt><dd>~a</dd>~%" 
			   (inline (second m)) (inline (or (third m) "")))))
	       ((string-match (rx +u-list+) ln) =>
		(lambda (m)
		  (push-tag `(ul . ,(string-length (second m))) out)
		  (set! *list-continuation* #t)
		  (fprintf out "<li>~a~%" (inline (third m)))))
	       ((string-match (rx +o-list+) ln) =>
		(lambda (m)
		  (push-tag `(ol . ,(string-length (second m))) out)
		  (set! *list-continuation* #t)
		  (fprintf out "<li>~a~%" (inline (third m)))))
	       (else (error "unknown block match" m))�)
	 (loop))))))


;;; Substitute inline elements

(define (inline str)
  (or (and-let* ((m (string-search-positions (rx +inline-element+) str)))
	(string-append
	 (clean (substring str 0 (caar m)))
	 (let ((rest (substring str (caar m))))
	   (define (continue m)
	     (inline (substring rest (string-length (first m)))))
	   (cond ((string-search (rx `(: bos ,+code+)) rest) =>
		  (lambda (m)
		    (string-append 
		     "<tt>" (clean (second m)) "</tt>"
		     (continue m))))
		 ((string-search (rx `(: bos ,+html-tag+)) rest) =>
		  (lambda (m)
		    (string-append
		     (first m)
		     (continue m))))
		 ((string-search (rx `(: bos ,+link+)) rest) =>
		  (lambda (m)
		    (let ((m1 (string-trim-both (second m))))
		      (string-append
		       (cond ((or (string=? "toc:" m1)
				  (string-search (rx '(: bos (* space) "tags:")) m1) )
			      "")
			     ((member m1 *manual-pages*)
			      (string-append 
			       "<a href='" (clean m1) ".html'>" (inline m1) "</a>"))
			     (else
			      (string-append
			       "<a href='" 
			       (clean
				(let ((href (second m)))
				  (if (string-match (rx +http-url+) href)
				      href
				      (string-append "http://chicken.wiki.br/" href))))
			       "'>"
			       (clean (or (third m) (second m)))
			       "</a>")))
		       (continue m)))))
		 ((string-search (rx `(: bos ,+bold+)) rest) =>
		  (lambda (m)
		    (string-append
		     "<b>" (inline (second m)) "</b>"
		     (continue m)))) 
		 ((string-search (rx `(: bos ,+italic+)) rest) =>
		  (lambda (m)
		    (string-append
		     "<i>" (inline (second m)) "</i>"
		     (continue m)))) 
		 (else (error "unknown inline match" m rest))))))
      str))

(define (convert name)
  (let ((sxml (html->sxml (open-input-string (with-output-to-string wiki->html)))))
    (define (walk n)
      (match n
	(('*PI* . _) "")
	(('enscript strs ...)
	 `(pre ,@(match strs
		   ((('@ . _) . strs) strs)
		   (_ strs))))
	(('procedure strs ...)
	 `(pre "\n [procedure] " ,@strs))
	(((? symbol? tag) ('@ attr ...) . body)
	 `(,tag (@ ,@attr) ,@(map walk body)))
	(((? symbol? tag) . body)
	 `(,tag ,@(map walk body)))
	(_ n)))
    (display
     (shtml->html
      (let ((sxml (wrap name (walk `(body ,@(cdr sxml))))))
	;(pp sxml (current-error-port))
	sxml)))))

(define (wrap name body)
  `(html (head (title ,(string-append "The CHICKEN User's Manual - " name))
	       (style (@ (type "text/css"))
		 "@import url('manual.css');\n"))
	 ,body))


;;; Normalize text

(define (clean str)
  (string-translate* str '(("<" . "&lt;") ("&" . "&amp;") ("'" . "&apos;") ("\"" . "&quot;"))))


;;; Run it

(define (main args)
  (let ((outdir "."))
    (let loop ((args args))
      (match args
	(()
	 (print "usage: wiki2html [-o DIRECTORY] PAGEFILE ...")
	 (exit 1))
	(("-o" dir . more)
	 (set! outdir dir)
	 (loop more))
	((files ...)
	 (let ((dirs (delete-duplicates (map pathname-directory files) string=?)))
	   (set! *manual-pages* (map pathname-strip-directory (append-map directory dirs)))
	   (for-each
	    (lambda (file)
	      (print file)
	      (with-input-from-file file 
		(lambda ()
		  (with-output-to-file (pathname-replace-directory (string-append file ".html") outdir) 
		    (cut convert (pathname-file file))))))
	    files)))))))


(main (command-line-arguments))
