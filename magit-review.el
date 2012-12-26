;; Magit-review
;; ------------
;;
;; Copyright (C) 2012, Christopher Allan Webber
;;
;; magit-review is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.



;; This is a BUFFER LOCAL VARIABLE, do not set.
(defvar magit-review/review-state
  nil
  "State of reviews in this magit-review buffer.

Contains the user marks of what is and isn't in what state of review.

Doesn't contain info on whether or not there's anything new to be
seen in the branch.

Buffer-local; do not set manually!")
(make-variable-buffer-local 'magit-review/review-state)

(defvar magit-review/review-state-changed
  nil
  "Whether or not the review state has changed since last being serialized")
(make-variable-buffer-local 'magit-review/review-state-changed)


;;; Format of review metadata
;;; -------------------------
;; 
;; Here's a mini json representation:
;; 
;;   {"refs/remotes/bretts/bug419-chunk-reads": {
;;      "state": "tracked:review",
;;      "notes": "We'll come back to this later"},
;;    "refs/remotes/bretts/keyboard_nav": {
;;      "state": "tracked:deferred"},
;;    "refs/remotes/bretts/master": {
;;      "state": "tracked:review"},
;;    "refs/remotes/bretts/newlayout": {
;;      "state": "ignored:ignored"},
;;    "refs/remotes/bretts/newlayout-stage": {
;;      "state": "ignored:nothingnew"},
;;    "refs/remotes/chemhacker/349_rssfeed": {
;;      "state": "ignored:ignored"},
;;    "refs/remotes/chemhacker/bug178_userlist": {
;;      "state": "ignored:nothingnew"}}


;; Review file management
;; ----------------------
;; 
;; Review file is jsonified versions of the local
;; magit-review/review-state alist variable.

; Get the review file
(defun magit-review/get-review-file ()
  (concat (magit-git-dir) "info/magit-review"))


; Load review file
(defun magit-review/read-review-file ()
  "Read the review file and get back an alist"
  (let ((magit-review-file magit-review/get-review-file)
        (json-key-type 'string)
        (json-object-type 'alist))
    (if (file-exists-p magit-review-file)
        (json-read-file magit-review-file))))

(defun magit-review/load-review-file ()
  "Read the review file into the buffer-local state of reviewing"
  (setq magit-review/review-state (magit-review/read-review-file)))


; Serialize current state
(defun magit-review/serialize-review-state ()
  "Serialize the current state of reviews to file."
  (let ((magit-review-file magit-review/get-review-file)
        (jsonified-review-state
         (json-encode-alist magit-review/review-state)))
    ; Move the old file aside
    (magit-review/move-old-review-file-if-exists)
    ; Write a new file
    (with-temp-file
        magit-review-file
      (insert jsonified-review-state))))
   

(defun magit-review/move-old-review-file-if-exists ()
  "If the old magit-review file exists, move it aside."
  (let ((magit-review-file magit-review/get-review-file))
    (if (file-exists-p magit-review-file)
        (rename-file magit-review-file
                     (concat (magit-git-dir) "info/magit-review.old")
                     t))))


;; Branch filtering
;; ----------------

(defvar magit-review/filter-rule
  "tracked=all ignored=none other=new"
  "String to state how things are being filtered.

Basically, with a string like:

  tracked=all ignored=none other=new

this will mean:
 - All tracked branches (eg, tracked:review or tracked:deferred,
   whatever) will be shown, regardless of whether there's new commits or not.
 - All ignored branches (eg, ignored:ignored and
   ignored:nothingnew) will be ignored, regardless of whatever
 - Anything else will be displayed, but *only* if there are new commits.

You can get more specific also, like:
 tracked:review=all tracked:deferred=new ignored=none other=new

Valid states are... well anything, though convention is to use
\"tracked\" and \"ignored\" for keeping note of what to track or
ignore... but you could use anything.  There are some special
cases though... \"unknown\" means it does not have any state
assigned to it, and \"other\" is used to say \"anything that has
not matched yet will match this\", and you should always set it
last in your filter rule if using.

Valid directives are:
 - all (show everything)
 - none (show nothing)
 - new (show only things with new commits)
 - nothing-new (show only things that have no new commits)
")

(defun magit-review/parse-filter-string (&optional filter-string)
  "Take a filter string and break it into filter coponents.

So:
  tracked=all ignored=none other=new

will become:
  ((\"tracked\" \"all\")
   (\"ignored\" \"none\")
   (\"other\" \"new\"))

You can pass this FILTER-STRING; otherwise it will process
magit-review/filter-rule"
  (let ((filter-string (or filter-string magit-review/filter-rule)))
    (mapcar
     (lambda (item) (split-string item "="))
     (split-string filter-string))))


(defun magit-review/determine-matching-rule (branch-state rules)
  "Return a matching rule... if we can find one.

Note: if the branch doesn't have a state, it's convention to set
it as \"untracked\" before passing it in here.
"
  (let ((branch-state-components (split-string branch-state ":")))
    (block matching-rule-finder
      (loop
       for rule in rules do
       (let* ((rule-state (car rule))
              (rule-state-components (split-string rule-state ":")))
         (if (or
              ; it's other, which should always go last, so this is a catch-all
              (equal rule-state "other")
              ; they're the same thing; that's a match
              (equal rule-state branch-state)
              ; this is a "catch-many" rule, and it's multi-component
              (and (= (length rule-state-components) 1)
                   (> (length branch-state-components) 1)
                   (equal (car branch-state-components) rule-state))
              ; the branch state is none and this is an "untracked" rule
              (and (equal branch-state nil)
                   (equal rule-state "untracked")))
             (return-from matching-rule-finder rule)))))))


(defun magit-review/has-new-commits (branch-name)
  "See if this branch has any new commits in it."
  (> (length (magit-git-lines
              "log" "--pretty=oneline"
              (concat "HEAD" ".." branch-name)))
     0))


(defun magit-review/should-include-branch (branch-name rule-directive)
  "Should we include anything new in this branch? Check!"
  (cond
   ; always include branches under an "all" directive
   ((equal rule-directive "all") t)
   ; never include any branches marked none
   ((equal rule-directive "none") nil)
   ((and (equal rule-directive "new")
         (magit-review/has-new-commits branch-name)) t)
   ((and (equal rule-directive "nothing-new")
         (not (magit-review/has-new-commits branch-name))) t)))


(defvar magit-review/default-directive
  "new"
  "Default directive if we don't find a matching rule.")


(defun magit-review/filter-branches (&optional refs-to-check filter-rules)
  "Return a filtered set of branches

This function weeds out the ones that shouldn't be shown.

The returned a plist which will look something like:
  ((\"untracked\" . (\"refs/remotes/bretts/keyboard_nav\"
                     \"refs/remotes/bretts/master\")
   (\"tracked:review\" . (\"refs/remotes/bretts/newlayout\"
                          \"refs/remotes/bretts/newlayout-stage\"))))
"
  (let ((refs-to-check
         (or refs-to-check
             (mapcar (lambda (x) (cdr x)) (magit-list-interesting-refs))))
        (filter-rules (or filter-rules (magit-review/parse-filter-string)))
        (filtered-branches nil))
    (mapc
     (lambda (branch-name)
       (let* ((branch-state
               (or (assoc "state"
                          (assoc branch-name
                                 magit-review/review-state))
                   "unknown"))
              ;; (branch-rule
              ;;  (magit-review/determine-matching-rule
              ;;   branch-name branch-state filter-rules))
              (matching-rule
               (magit-review/determine-matching-rule
                branch-state filter-rules))
              (matching-rule-state
               (if matching-rule
                   (car matching-rule)
                 "unknown"))
              (matching-rule-directive
               (if matching-rule
                   (nth 1 matching-rule)
                 magit-review/default-directive)))
         ; If we should include the branch, let's include it!
         (if (magit-review/should-include-branch
              branch-name matching-rule-directive)

             ; File this branch with the other branches of its type
             (setq filtered-branches
                   (lax-plist-put
                    filtered-branches branch-state
                    (cons branch-name
                          (lax-plist-get filtered-branches branch-state)))))))
     refs-to-check)
    filtered-branches))
           
;; magit-review display

(define-derived-mode magit-review-mode magit-mode "Magit Review"
  "Mode for looking at commits that could be merged from other branches.

\\{magit-review-mode-map}"
  :group 'magit)

(defun magit-review (&optional all)
  (interactive "P")
  (let ((topdir (magit-get-top-dir default-directory))
        (current-branch (magit-get-current-branch)))
    (magit-buffer-switch "*magit-review*")
    (magit-mode-init topdir 'magit-review-mode
                     #'magit-refresh-review-buffer
                     current-branch all)))

