;; Execution Tracking Contract
;; Monitors approved proposal implementation and tracks progress

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_EXECUTION_NOT_FOUND (err u301))
(define-constant ERR_INVALID_STATUS (err u302))
(define-constant ERR_INVALID_MILESTONE (err u303))
(define-constant ERR_EXECUTION_COMPLETE (err u304))

;; Data Variables
(define-data-var execution-counter uint u0)
(define-data-var default-execution-period uint u4032) ;; ~4 weeks in blocks

;; Data Maps
(define-map execution-records
  { execution-id: uint }
  {
    proposal-id: uint,
    executor: principal,
    status: (string-ascii 20), ;; "pending", "in-progress", "completed", "failed", "cancelled"
    start-block: uint,
    target-completion: uint,
    actual-completion: (optional uint),
    total-milestones: uint,
    completed-milestones: uint,
    budget-allocated: uint,
    budget-used: uint
  }
)

(define-map execution-milestones
  { execution-id: uint, milestone-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 300),
    target-block: uint,
    completion-block: (optional uint),
    status: (string-ascii 20), ;; "pending", "in-progress", "completed", "overdue"
    evidence-hash: (optional (buff 32)),
    reviewer: (optional principal),
    review-status: (string-ascii 20) ;; "pending", "approved", "rejected"
  }
)

(define-map execution-evidence
  { execution-id: uint, evidence-id: uint }
  {
    evidence-type: (string-ascii 50), ;; "document", "code", "report", "media"
    evidence-hash: (buff 32),
    description: (string-ascii 200),
    submitted-by: principal,
    submission-block: uint,
    verified: bool,
    verifier: (optional principal)
  }
)

(define-map execution-updates
  { execution-id: uint, update-id: uint }
  {
    update-text: (string-ascii 500),
    progress-percentage: uint,
    submitted-by: principal,
    submission-block: uint,
    milestone-reference: (optional uint)
  }
)

(define-map execution-reviewers
  { execution-id: uint }
  { reviewers: (list 10 principal), lead-reviewer: principal }
)

;; Read-only functions
(define-read-only (get-execution-record (execution-id uint))
  (map-get? execution-records { execution-id: execution-id })
)

(define-read-only (get-execution-milestone (execution-id uint) (milestone-id uint))
  (map-get? execution-milestones { execution-id: execution-id, milestone-id: milestone-id })
)

(define-read-only (get-execution-evidence (execution-id uint) (evidence-id uint))
  (map-get? execution-evidence { execution-id: execution-id, evidence-id: evidence-id })
)

(define-read-only (get-execution-update (execution-id uint) (update-id uint))
  (map-get? execution-updates { execution-id: execution-id, update-id: update-id })
)

(define-read-only (get-execution-reviewers (execution-id uint))
  (map-get? execution-reviewers { execution-id: execution-id })
)

(define-read-only (get-execution-progress (execution-id uint))
  (match (get-execution-record execution-id)
    record (let (
      (completed (get completed-milestones record))
      (total (get total-milestones record))
    )
      (if (> total u0)
        (some (/ (* completed u100) total))
        (some u0)
      )
    )
    none
  )
)

(define-read-only (is-execution-overdue (execution-id uint))
  (match (get-execution-record execution-id)
    record (and
             (> block-height (get target-completion record))
             (not (is-eq (get status record) "completed")))
    false
  )
)

(define-read-only (get-execution-counter)
  (var-get execution-counter)
)

;; Private functions
(define-private (max (a uint) (b uint))
  (if (> a b) a b)
)

;; Public functions
(define-public (create-execution-record
  (proposal-id uint)
  (executor principal)
  (duration-blocks uint)
  (total-milestones uint)
  (budget-allocated uint)
)
  (let (
    (execution-id (+ (var-get execution-counter) u1))
    (start-block block-height)
    (target-completion (+ start-block (max duration-blocks (var-get default-execution-period))))
  )
    ;; Validate inputs
    (asserts! (> total-milestones u0) ERR_INVALID_MILESTONE)
    (asserts! (> duration-blocks u0) ERR_INVALID_STATUS)

    ;; Create execution record
    (map-set execution-records
      { execution-id: execution-id }
      {
        proposal-id: proposal-id,
        executor: executor,
        status: "pending",
        start-block: start-block,
        target-completion: target-completion,
        actual-completion: none,
        total-milestones: total-milestones,
        completed-milestones: u0,
        budget-allocated: budget-allocated,
        budget-used: u0
      }
    )

    ;; Update counter
    (var-set execution-counter execution-id)

    (ok execution-id)
  )
)

(define-public (start-execution (execution-id uint))
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
  )
    ;; Only executor or owner can start execution
    (asserts! (or (is-eq tx-sender (get executor record)) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status record) "pending") ERR_INVALID_STATUS)

    ;; Update status
    (map-set execution-records
      { execution-id: execution-id }
      (merge record { status: "in-progress" })
    )

    (ok true)
  )
)

(define-public (add-milestone
  (execution-id uint)
  (milestone-id uint)
  (title (string-ascii 100))
  (description (string-ascii 300))
  (target-block uint)
)
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
  )
    ;; Only executor can add milestones
    (asserts! (is-eq tx-sender (get executor record)) ERR_UNAUTHORIZED)
    (asserts! (> target-block block-height) ERR_INVALID_MILESTONE)

    ;; Add milestone
    (map-set execution-milestones
      { execution-id: execution-id, milestone-id: milestone-id }
      {
        title: title,
        description: description,
        target-block: target-block,
        completion-block: none,
        status: "pending",
        evidence-hash: none,
        reviewer: none,
        review-status: "pending"
      }
    )

    (ok true)
  )
)

(define-public (complete-milestone
  (execution-id uint)
  (milestone-id uint)
  (evidence-hash (buff 32))
)
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
    (milestone (unwrap! (get-execution-milestone execution-id milestone-id) ERR_INVALID_MILESTONE))
  )
    ;; Only executor can complete milestones
    (asserts! (is-eq tx-sender (get executor record)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status milestone) "pending") ERR_INVALID_STATUS)

    ;; Update milestone
    (map-set execution-milestones
      { execution-id: execution-id, milestone-id: milestone-id }
      (merge milestone {
        completion-block: (some block-height),
        status: "completed",
        evidence-hash: (some evidence-hash)
      })
    )

    ;; Update execution record
    (map-set execution-records
      { execution-id: execution-id }
      (merge record {
        completed-milestones: (+ (get completed-milestones record) u1)
      })
    )

    (ok true)
  )
)

(define-public (submit-evidence
  (execution-id uint)
  (evidence-id uint)
  (evidence-type (string-ascii 50))
  (evidence-hash (buff 32))
  (description (string-ascii 200))
)
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
  )
    ;; Only executor can submit evidence
    (asserts! (is-eq tx-sender (get executor record)) ERR_UNAUTHORIZED)

    ;; Store evidence
    (map-set execution-evidence
      { execution-id: execution-id, evidence-id: evidence-id }
      {
        evidence-type: evidence-type,
        evidence-hash: evidence-hash,
        description: description,
        submitted-by: tx-sender,
        submission-block: block-height,
        verified: false,
        verifier: none
      }
    )

    (ok true)
  )
)

(define-public (submit-progress-update
  (execution-id uint)
  (update-id uint)
  (update-text (string-ascii 500))
  (progress-percentage uint)
  (milestone-reference (optional uint))
)
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
  )
    ;; Only executor can submit updates
    (asserts! (is-eq tx-sender (get executor record)) ERR_UNAUTHORIZED)
    (asserts! (<= progress-percentage u100) ERR_INVALID_STATUS)

    ;; Store update
    (map-set execution-updates
      { execution-id: execution-id, update-id: update-id }
      {
        update-text: update-text,
        progress-percentage: progress-percentage,
        submitted-by: tx-sender,
        submission-block: block-height,
        milestone-reference: milestone-reference
      }
    )

    (ok true)
  )
)

(define-public (verify-evidence
  (execution-id uint)
  (evidence-id uint)
  (verified bool)
)
  (let (
    (evidence (unwrap! (get-execution-evidence execution-id evidence-id) ERR_EXECUTION_NOT_FOUND))
    (reviewers (get-execution-reviewers execution-id))
  )
    ;; Only reviewers can verify evidence
    (asserts! (match reviewers
                rev (or (is-eq tx-sender (get lead-reviewer rev))
                       (is-some (index-of (get reviewers rev) tx-sender)))
                false) ERR_UNAUTHORIZED)

    ;; Update evidence
    (map-set execution-evidence
      { execution-id: execution-id, evidence-id: evidence-id }
      (merge evidence {
        verified: verified,
        verifier: (some tx-sender)
      })
    )

    (ok true)
  )
)

(define-public (complete-execution (execution-id uint))
  (let (
    (record (unwrap! (get-execution-record execution-id) ERR_EXECUTION_NOT_FOUND))
  )
    ;; Only executor or owner can complete execution
    (asserts! (or (is-eq tx-sender (get executor record)) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status record) "in-progress") ERR_INVALID_STATUS)

    ;; Check if all milestones are completed
    (asserts! (is-eq (get completed-milestones record) (get total-milestones record)) ERR_INVALID_STATUS)

    ;; Update execution record
    (map-set execution-records
      { execution-id: execution-id }
      (merge record {
        status: "completed",
        actual-completion: (some block-height)
      })
    )

    (ok true)
  )
)

(define-public (set-execution-reviewers
  (execution-id uint)
  (reviewers (list 10 principal))
  (lead-reviewer principal)
)
  (begin
    ;; Only contract owner can set reviewers
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set execution-reviewers
      { execution-id: execution-id }
      {
        reviewers: reviewers,
        lead-reviewer: lead-reviewer
      }
    )

    (ok true)
  )
)
