;; Smart Contract Insurance Claim Validator
;; Validates insurance claims against predefined criteria
;; Provides automated claim verification and payout processing

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u200))
(define-constant ERR_CLAIM_NOT_FOUND (err u201))
(define-constant ERR_INVALID_POLICY (err u202))
(define-constant ERR_CLAIM_ALREADY_EXISTS (err u203))
(define-constant ERR_INSUFFICIENT_EVIDENCE (err u204))
(define-constant ERR_CLAIM_ALREADY_PROCESSED (err u205))
(define-constant ERR_POLICY_INACTIVE (err u206))
(define-constant ERR_INVALID_CLAIM_AMOUNT (err u207))
(define-constant ERR_INSUFFICIENT_FUNDS (err u208))
(define-constant CLAIM_PENDING u1)
(define-constant CLAIM_APPROVED u2)
(define-constant CLAIM_REJECTED u3)
(define-constant CLAIM_PAID u4)
(define-constant MIN_EVIDENCE_PIECES u3)
(define-constant MAX_CLAIM_PROCESSING_BLOCKS u1008) ;; ~7 days

;; Data Variables
(define-data-var next-claim-id uint u1)
(define-data-var total-claims uint u0)
(define-data-var total-payouts uint u0)
(define-data-var claim-processing-fee uint u50000) ;; 0.05 STX in microstx
(define-data-var auto-approve-threshold uint u5000000) ;; 5 STX auto-approve limit

;; Data Maps
(define-map claims
  { claim-id: uint }
  {
    policy-id: uint,
    claimant: principal,
    claim-amount: uint,
    incident-description: (string-ascii 500),
    evidence-hash: (string-ascii 64),
    submitted-at: uint,
    status: uint,
    processed-at: (optional uint),
    validator: (optional principal),
    rejection-reason: (optional (string-ascii 200))
  }
)

(define-map claim-evidence
  { claim-id: uint, evidence-index: uint }
  {
    evidence-type: (string-ascii 50),
    evidence-hash: (string-ascii 64),
    submitted-by: principal,
    timestamp: uint,
    is-verified: bool
  }
)

(define-map claim-votes
  { claim-id: uint, validator: principal }
  {
    vote: bool, ;; true for approve, false for reject
    reasoning: (string-ascii 200),
    timestamp: uint
  }
)

(define-map authorized-validators
  { validator: principal }
  {
    is-authorized: bool,
    reputation-score: uint,
    total-claims-validated: uint,
    accuracy-rate: uint
  }
)

(define-map claim-statistics
  { claimant: principal }
  {
    total-claims: uint,
    approved-claims: uint,
    rejected-claims: uint,
    total-received: uint
  }
)

;; Private Functions

(define-private (is-authorized-validator (validator principal))
  (default-to false (get is-authorized (map-get? authorized-validators { validator: validator })))
)

(define-private (count-evidence-pieces (claim-id uint))
  (let (
    (evidence-0 (map-get? claim-evidence { claim-id: claim-id, evidence-index: u0 }))
    (evidence-1 (map-get? claim-evidence { claim-id: claim-id, evidence-index: u1 }))
    (evidence-2 (map-get? claim-evidence { claim-id: claim-id, evidence-index: u2 }))
    (evidence-3 (map-get? claim-evidence { claim-id: claim-id, evidence-index: u3 }))
    (evidence-4 (map-get? claim-evidence { claim-id: claim-id, evidence-index: u4 }))
  )
    (+ 
      (if (is-some evidence-0) u1 u0)
      (+ 
        (if (is-some evidence-1) u1 u0)
        (+ 
          (if (is-some evidence-2) u1 u0)
          (+ 
            (if (is-some evidence-3) u1 u0)
            (if (is-some evidence-4) u1 u0)
          )
        )
      )
    )
  )
)

(define-private (calculate-validator-consensus (claim-id uint))
  (let (
    (vote-0 (map-get? claim-votes { claim-id: claim-id, validator: CONTRACT_OWNER }))
    (vote-1 (map-get? claim-votes { claim-id: claim-id, validator: tx-sender }))
  )
    ;; Simplified consensus - in production, would iterate through all validators
    (if (and (is-some vote-0) (is-some vote-1))
      (and (get vote (unwrap-panic vote-0)) (get vote (unwrap-panic vote-1)))
      false
    )
  )
)

(define-private (update-claim-statistics (claimant principal) (amount uint) (approved bool))
  (let (
    (current-stats (default-to 
      { total-claims: u0, approved-claims: u0, rejected-claims: u0, total-received: u0 }
      (map-get? claim-statistics { claimant: claimant })
    ))
  )
    (map-set claim-statistics
      { claimant: claimant }
      {
        total-claims: (+ (get total-claims current-stats) u1),
        approved-claims: (if approved (+ (get approved-claims current-stats) u1) (get approved-claims current-stats)),
        rejected-claims: (if approved (get rejected-claims current-stats) (+ (get rejected-claims current-stats) u1)),
        total-received: (if approved (+ (get total-received current-stats) amount) (get total-received current-stats))
      }
    )
  )
)

(define-private (process-automatic-approval (claim-id uint) (claim-amount uint))
  (if (<= claim-amount (var-get auto-approve-threshold))
    (begin
      (map-set claims
        { claim-id: claim-id }
        (merge 
          (unwrap-panic (map-get? claims { claim-id: claim-id }))
          {
            status: CLAIM_APPROVED,
            processed-at: (some block-height),
            validator: (some CONTRACT_OWNER)
          }
        )
      )
      true
    )
    false
  )
)

;; Public Functions

;; Submit insurance claim
(define-public (submit-claim 
  (policy-id uint)
  (claim-amount uint)
  (incident-description (string-ascii 500))
  (evidence-hash (string-ascii 64))
)
  (let (
    (claim-id (var-get next-claim-id))
  )
    (asserts! (> claim-amount u0) ERR_INVALID_CLAIM_AMOUNT)
    (asserts! (is-none (map-get? claims { claim-id: claim-id })) ERR_CLAIM_ALREADY_EXISTS)
    
    ;; Create claim record
    (map-set claims
      { claim-id: claim-id }
      {
        policy-id: policy-id,
        claimant: tx-sender,
        claim-amount: claim-amount,
        incident-description: incident-description,
        evidence-hash: evidence-hash,
        submitted-at: block-height,
        status: CLAIM_PENDING,
        processed-at: none,
        validator: none,
        rejection-reason: none
      }
    )
    
    ;; Try automatic approval for small claims
    (if (process-automatic-approval claim-id claim-amount)
      (print "Claim auto-approved")
      (print "Claim submitted for review")
    )
    
    ;; Update counters
    (var-set next-claim-id (+ claim-id u1))
    (var-set total-claims (+ (var-get total-claims) u1))
    
    (ok claim-id)
  )
)

;; Add evidence to claim
(define-public (add-evidence 
  (claim-id uint)
  (evidence-index uint)
  (evidence-type (string-ascii 50))
  (evidence-hash (string-ascii 64))
)
  (let (
    (claim (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get claimant claim)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status claim) CLAIM_PENDING) ERR_CLAIM_ALREADY_PROCESSED)
    (asserts! (< evidence-index u5) ERR_INSUFFICIENT_EVIDENCE) ;; Max 5 evidence pieces
    
    (map-set claim-evidence
      { claim-id: claim-id, evidence-index: evidence-index }
      {
        evidence-type: evidence-type,
        evidence-hash: evidence-hash,
        submitted-by: tx-sender,
        timestamp: block-height,
        is-verified: false
      }
    )
    (ok true)
  )
)

;; Validate claim (validators only)
(define-public (validate-claim 
  (claim-id uint)
  (approve bool)
  (reasoning (string-ascii 200))
)
  (let (
    (claim (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
    (evidence-count (count-evidence-pieces claim-id))
  )
    (asserts! (is-authorized-validator tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status claim) CLAIM_PENDING) ERR_CLAIM_ALREADY_PROCESSED)
    (asserts! (>= evidence-count MIN_EVIDENCE_PIECES) ERR_INSUFFICIENT_EVIDENCE)
    
    ;; Record validator vote
    (map-set claim-votes
      { claim-id: claim-id, validator: tx-sender }
      {
        vote: approve,
        reasoning: reasoning,
        timestamp: block-height
      }
    )
    
    ;; Update claim status based on validation
    (map-set claims
      { claim-id: claim-id }
      (merge claim
        {
          status: (if approve CLAIM_APPROVED CLAIM_REJECTED),
          processed-at: (some block-height),
          validator: (some tx-sender),
          rejection-reason: (if approve none (some reasoning))
        }
      )
    )
    
    ;; Update statistics
    (update-claim-statistics (get claimant claim) (get claim-amount claim) approve)
    
    (ok approve)
  )
)

;; Process claim payout
(define-public (process-payout (claim-id uint))
  (let (
    (claim (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
    (payout-amount (get claim-amount claim))
  )
    (asserts! (is-eq (get status claim) CLAIM_APPROVED) ERR_INVALID_POLICY)
    (asserts! (>= (stx-get-balance (as-contract tx-sender)) payout-amount) ERR_INSUFFICIENT_FUNDS)
    
    ;; Transfer payout to claimant
    (try! (as-contract (stx-transfer? payout-amount tx-sender (get claimant claim))))
    
    ;; Update claim status
    (map-set claims
      { claim-id: claim-id }
      (merge claim { status: CLAIM_PAID })
    )
    
    ;; Update total payouts
    (var-set total-payouts (+ (var-get total-payouts) payout-amount))
    
    (ok payout-amount)
  )
)

;; Read-only Functions

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? claims { claim-id: claim-id })
)

;; Get claim evidence
(define-read-only (get-claim-evidence (claim-id uint) (evidence-index uint))
  (map-get? claim-evidence { claim-id: claim-id, evidence-index: evidence-index })
)

;; Get validator vote
(define-read-only (get-validator-vote (claim-id uint) (validator principal))
  (map-get? claim-votes { claim-id: claim-id, validator: validator })
)

;; Get claim statistics for user
(define-read-only (get-claim-stats (claimant principal))
  (default-to 
    { total-claims: u0, approved-claims: u0, rejected-claims: u0, total-received: u0 }
    (map-get? claim-statistics { claimant: claimant })
  )
)

;; Get platform claim statistics
(define-read-only (get-platform-claim-stats)
  {
    total-claims: (var-get total-claims),
    total-payouts: (var-get total-payouts),
    processing-fee: (var-get claim-processing-fee),
    auto-approve-threshold: (var-get auto-approve-threshold),
    next-claim-id: (var-get next-claim-id)
  }
)

;; Administrative Functions

;; Authorize claim validator
(define-public (authorize-validator (validator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set authorized-validators
      { validator: validator }
      {
        is-authorized: true,
        reputation-score: u75,
        total-claims-validated: u0,
        accuracy-rate: u100
      }
    )
    (ok true)
  )
)

;; Update auto-approval threshold
(define-public (set-auto-approve-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set auto-approve-threshold new-threshold)
    (ok new-threshold)
  )
)

;; Emergency claim rejection
(define-public (emergency-reject-claim (claim-id uint) (reason (string-ascii 200)))
  (let (
    (claim (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set claims
      { claim-id: claim-id }
      (merge claim
        {
          status: CLAIM_REJECTED,
          processed-at: (some block-height),
          validator: (some tx-sender),
          rejection-reason: (some reason)
        }
      )
    )
    (ok true)
  )
)

