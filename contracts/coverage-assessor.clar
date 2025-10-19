;; Smart Contract Insurance Coverage Assessor
;; Assesses smart contract risks and determines coverage terms
;; Provides automated risk scoring and premium calculation

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_RISK_SCORE (err u101))
(define-constant ERR_POLICY_NOT_FOUND (err u102))
(define-constant ERR_INSUFFICIENT_PAYMENT (err u103))
(define-constant ERR_POLICY_EXPIRED (err u104))
(define-constant ERR_INVALID_DURATION (err u105))
(define-constant MIN_RISK_SCORE u1)
(define-constant MAX_RISK_SCORE u100)
(define-constant BASE_PREMIUM u1000000) ;; 1 STX in microstx
(define-constant MAX_COVERAGE u100000000000) ;; 100,000 STX max coverage
(define-constant MIN_DURATION u30) ;; 30 days minimum
(define-constant MAX_DURATION u365) ;; 1 year maximum

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var total-policies uint u0)
(define-data-var total-premium-collected uint u0)
(define-data-var platform-fee-rate uint u5) ;; 5% platform fee

;; Data Maps
(define-map policies
  { policy-id: uint }
  {
    contract-address: principal,
    policy-holder: principal,
    coverage-amount: uint,
    premium-paid: uint,
    risk-score: uint,
    start-block: uint,
    end-block: uint,
    is-active: bool,
    assessment-timestamp: uint
  }
)

(define-map risk-assessments
  { contract-address: principal }
  {
    risk-score: uint,
    complexity-factor: uint,
    historical-incidents: uint,
    last-assessment: uint,
    assessor: principal
  }
)

(define-map authorized-assessors
  { assessor: principal }
  { is-authorized: bool, reputation-score: uint }
)

(define-map policy-metrics
  { policy-holder: principal }
  { total-policies: uint, total-premium-paid: uint, claims-filed: uint }
)

;; Private Functions

(define-private (calculate-premium (coverage-amount uint) (risk-score uint) (duration-days uint))
  (let (
    (base-calculation (* BASE_PREMIUM (/ coverage-amount u1000000)))
    (risk-multiplier (+ u100 (* risk-score u2)))
    (duration-factor (+ u100 (/ duration-days u10)))
    (premium-before-fees (/ (* (* base-calculation risk-multiplier) duration-factor) u10000))
  )
    (+ premium-before-fees (/ (* premium-before-fees (var-get platform-fee-rate)) u100))
  )
)

(define-private (is-valid-risk-score (score uint))
  (and (>= score MIN_RISK_SCORE) (<= score MAX_RISK_SCORE))
)

(define-private (is-authorized-caller (caller principal))
  (or 
    (is-eq caller CONTRACT_OWNER)
    (default-to false (get is-authorized (map-get? authorized-assessors { assessor: caller })))
  )
)

(define-private (update-policy-metrics (policy-holder principal) (premium uint))
  (let (
    (current-metrics (default-to 
      { total-policies: u0, total-premium-paid: u0, claims-filed: u0 }
      (map-get? policy-metrics { policy-holder: policy-holder })
    ))
  )
    (map-set policy-metrics
      { policy-holder: policy-holder }
      {
        total-policies: (+ (get total-policies current-metrics) u1),
        total-premium-paid: (+ (get total-premium-paid current-metrics) premium),
        claims-filed: (get claims-filed current-metrics)
      }
    )
  )
)

(define-private (calculate-duration-blocks (duration-days uint))
  (if (and (>= duration-days MIN_DURATION) (<= duration-days MAX_DURATION))
    (* duration-days u144) ;; Assuming ~144 blocks per day
    u0
  )
)

;; Public Functions

;; Assess contract risk and store assessment
(define-public (assess-contract-risk 
  (contract-address principal) 
  (complexity-factor uint) 
  (historical-incidents uint)
)
  (let (
    (calculated-score (+ 
      (/ complexity-factor u10)
      (* historical-incidents u5)
      (if (> historical-incidents u0) u20 u5)
    ))
    (risk-score (if (> calculated-score MAX_RISK_SCORE) MAX_RISK_SCORE calculated-score))
  )
    (asserts! (is-authorized-caller tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (is-valid-risk-score risk-score) ERR_INVALID_RISK_SCORE)
    
    (map-set risk-assessments
      { contract-address: contract-address }
      {
        risk-score: risk-score,
        complexity-factor: complexity-factor,
        historical-incidents: historical-incidents,
        last-assessment: block-height,
        assessor: tx-sender
      }
    )
    (ok risk-score)
  )
)

;; Create insurance policy
(define-public (create-policy 
  (contract-address principal)
  (coverage-amount uint)
  (duration-days uint)
)
  (let (
    (policy-id (var-get next-policy-id))
    (assessment (unwrap! (map-get? risk-assessments { contract-address: contract-address }) ERR_POLICY_NOT_FOUND))
    (risk-score (get risk-score assessment))
    (premium (calculate-premium coverage-amount risk-score duration-days))
    (duration-blocks (calculate-duration-blocks duration-days))
  )
    (asserts! (> coverage-amount u0) ERR_INVALID_RISK_SCORE)
    (asserts! (<= coverage-amount MAX_COVERAGE) ERR_INVALID_RISK_SCORE)
    (asserts! (> duration-blocks u0) ERR_INVALID_DURATION)
    (asserts! (>= (stx-get-balance tx-sender) premium) ERR_INSUFFICIENT_PAYMENT)
    
    ;; Transfer premium payment
    (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
    
    ;; Create policy record
    (map-set policies
      { policy-id: policy-id }
      {
        contract-address: contract-address,
        policy-holder: tx-sender,
        coverage-amount: coverage-amount,
        premium-paid: premium,
        risk-score: risk-score,
        start-block: block-height,
        end-block: (+ block-height duration-blocks),
        is-active: true,
        assessment-timestamp: (get last-assessment assessment)
      }
    )
    
    ;; Update metrics
    (update-policy-metrics tx-sender premium)
    (var-set next-policy-id (+ policy-id u1))
    (var-set total-policies (+ (var-get total-policies) u1))
    (var-set total-premium-collected (+ (var-get total-premium-collected) premium))
    
    (ok policy-id)
  )
)

;; Get premium quote
(define-read-only (get-premium-quote 
  (contract-address principal)
  (coverage-amount uint)
  (duration-days uint)
)
  (match (map-get? risk-assessments { contract-address: contract-address })
    assessment (ok (calculate-premium coverage-amount (get risk-score assessment) duration-days))
    ERR_POLICY_NOT_FOUND
  )
)

;; Get policy details
(define-read-only (get-policy (policy-id uint))
  (map-get? policies { policy-id: policy-id })
)

;; Check if policy is active
(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? policies { policy-id: policy-id })
    policy (ok (and 
      (get is-active policy)
      (> (get end-block policy) block-height)
    ))
    ERR_POLICY_NOT_FOUND
  )
)

;; Get risk assessment
(define-read-only (get-risk-assessment (contract-address principal))
  (map-get? risk-assessments { contract-address: contract-address })
)

;; Get policy holder metrics
(define-read-only (get-policy-metrics (policy-holder principal))
  (default-to 
    { total-policies: u0, total-premium-paid: u0, claims-filed: u0 }
    (map-get? policy-metrics { policy-holder: policy-holder })
  )
)

;; Administrative Functions

;; Authorize risk assessor
(define-public (authorize-assessor (assessor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set authorized-assessors
      { assessor: assessor }
      { is-authorized: true, reputation-score: u50 }
    )
    (ok true)
  )
)

;; Deactivate policy (admin only)
(define-public (deactivate-policy (policy-id uint))
  (let (
    (policy (unwrap! (map-get? policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set policies
      { policy-id: policy-id }
      (merge policy { is-active: false })
    )
    (ok true)
  )
)

;; Update platform fee rate
(define-public (set-platform-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (<= new-rate u20) ERR_INVALID_RISK_SCORE) ;; Max 20% fee
    (var-set platform-fee-rate new-rate)
    (ok new-rate)
  )
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-policies: (var-get total-policies),
    total-premium-collected: (var-get total-premium-collected),
    platform-fee-rate: (var-get platform-fee-rate),
    next-policy-id: (var-get next-policy-id)
  }
)

