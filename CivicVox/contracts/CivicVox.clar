;; CivicVox: Decentralized Identity and Voting System
;; A smart contract that combines secure identity management with voting capabilities

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-registered (err u101))
(define-constant err-already-registered (err u102))
(define-constant err-already-voted (err u103))
(define-constant err-invalid-proposal (err u104))
(define-constant err-voting-closed (err u105))
(define-constant err-insufficient-funds (err u106))
(define-constant err-invalid-input (err u107))

;; Data Variables
(define-data-var voting-open bool false)
(define-data-var current-proposal-id uint u0)
(define-data-var registration-fee uint u1000000) ;; 1 STX registration fee

;; Data Maps
(define-map user-identities
  principal
  {
    kyc-status: bool,
    identity-hash: (string-utf8 64),
    registration-time: uint
  }
)

(define-map proposals
  uint
  {
    title: (string-utf8 100),
    description: (string-utf8 500),
    vote-count-yes: uint,
    vote-count-no: uint,
    end-block: uint,
    total-votes: uint
  }
)

(define-map votes
  {proposal-id: uint, voter: principal}
  bool
)

;; Private Functions
(define-private (is-registered (user principal))
  (default-to false (get kyc-status (map-get? user-identities user)))
)

(define-private (check-owner)
  (ok (asserts! (is-eq tx-sender contract-owner) err-owner-only))
)

;; Input Validation Functions
(define-private (validate-identity-hash (hash (string-utf8 64)))
  (and 
    (> (len hash) u0)
    (<= (len hash) u64)
  )
)

(define-private (validate-proposal-input 
  (title (string-utf8 100)) 
  (description (string-utf8 500))
  (duration uint)
)
  (and
    (> (len title) u0)
    (<= (len title) u100)
    (> (len description) u0)
    (<= (len description) u500)
    (> duration u0)
    (<= duration u52560) ;; Max 1 year in blocks
  )
)

;; Public Functions
(define-public (register-identity (identity-hash (string-utf8 64)))
  (let 
    (
      (fee (var-get registration-fee))
    )
    (asserts! (validate-identity-hash identity-hash) err-invalid-input)
    (asserts! (not (is-registered tx-sender)) err-already-registered)
    (asserts! (>= (stx-get-balance tx-sender) fee) err-insufficient-funds)
    
    ;; Transfer registration fee to contract owner
    (try! (stx-transfer? fee tx-sender contract-owner))
    
    (ok (map-set user-identities
      tx-sender
      {
        kyc-status: true,
        identity-hash: identity-hash,
        registration-time: stacks-block-height
      }
    ))
  )
)

(define-public (create-proposal 
  (title (string-utf8 100)) 
  (description (string-utf8 500)) 
  (duration uint)
)
  (let
    (
      (proposal-id (+ (var-get current-proposal-id) u1))
    )
    (asserts! (validate-proposal-input title description duration) err-invalid-input)
    (try! (check-owner))
    (map-set proposals
      proposal-id
      {
        title: title,
        description: description,
        vote-count-yes: u0,
        vote-count-no: u0,
        end-block: (+ stacks-block-height duration),
        total-votes: u0
      }
    )
    (var-set current-proposal-id proposal-id)
    (var-set voting-open true)
    (ok proposal-id)
  )
)

(define-public (cast-vote (proposal-id uint) (vote bool))
  (let
    (
      (proposal (unwrap! (map-get? proposals proposal-id) err-invalid-proposal))
      (vote-key {proposal-id: proposal-id, voter: tx-sender})
      (current-total-votes (get total-votes proposal))
    )
    (asserts! (is-registered tx-sender) err-not-registered)
    (asserts! (< stacks-block-height (get end-block proposal)) err-voting-closed)
    (asserts! (not (default-to false (map-get? votes vote-key))) err-already-voted)
    
    (map-set votes vote-key true)
    (if vote
      (map-set proposals proposal-id 
        (merge proposal 
          {
            vote-count-yes: (+ (get vote-count-yes proposal) u1),
            total-votes: (+ current-total-votes u1)
          }
        )
      )
      (map-set proposals proposal-id 
        (merge proposal 
          {
            vote-count-no: (+ (get vote-count-no proposal) u1),
            total-votes: (+ current-total-votes u1)
          }
        )
      )
    )
    (ok true)
  )
)

;; Administrative Functions
(define-public (update-registration-fee (new-fee uint))
  (begin
    (try! (check-owner))
    (asserts! (> new-fee u0) err-invalid-input)
    (var-set registration-fee new-fee)
    (ok true)
  )
)

;; Read-Only Functions
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id)
)

(define-read-only (get-user-identity (user principal))
  (map-get? user-identities user)
)

(define-read-only (has-voted (proposal-id uint) (user principal))
  (default-to false (map-get? votes {proposal-id: proposal-id, voter: user}))
)

(define-read-only (get-vote-results (proposal-id uint))
  (map-get? proposals proposal-id)
)

(define-read-only (get-registration-fee)
  (var-get registration-fee)
)