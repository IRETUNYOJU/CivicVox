;; CivicVox: Decentralized Identity and Voting System
;; A smart contract that combines secure identity management with voting capabilities and staking-based certification

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
(define-constant err-insufficient-stake (err u108))
(define-constant err-certification-dispute (err u109))
(define-constant err-invalid-certification (err u110))
(define-constant err-not-certification-authority (err u111))

;; Data Variables
(define-data-var voting-open bool false)
(define-data-var current-proposal-id uint u0)
(define-data-var registration-fee uint u1000000) ;; 1 STX registration fee
(define-data-var minimum-certification-stake uint u10000000) ;; 10 STX minimum stake
(define-data-var slashing-percentage uint u30) ;; 30% slashing for fraudulent certifications

;; Data Maps
(define-map user-identities
  principal
  {
    kyc-status: bool,
    identity-hash: (string-utf8 64),
    registration-time: uint,
    is-certification-authority: bool,
    staked-amount: uint
  }
)

(define-map certifications
  {
    authority: principal,
    certified-user: principal
  }
  {
    certification-hash: (string-utf8 64),
    timestamp: uint,
    is-disputed: bool,
    dispute-votes-yes: uint,
    dispute-votes-no: uint
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

(define-map certification-disputes
  {
    authority: principal,
    certified-user: principal
  }
  {
    dispute-start-block: uint,
    total-dispute-votes: uint,
    is-resolved: bool,
    dispute-votes-yes: uint,
    dispute-votes-no: uint
  }
)

;; Private Functions
(define-private (is-registered (user principal))
  (default-to false (get kyc-status (map-get? user-identities user)))
)

(define-private (is-certification-authority (user principal))
  (default-to false (get is-certification-authority (map-get? user-identities user)))
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

(define-private (validate-principal (user principal))
  (is-some (map-get? user-identities user))
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
    (asserts! (not (is-registered tx-sender)) err-already-registered)
    (asserts! (>= (stx-get-balance tx-sender) fee) err-insufficient-funds)
    (asserts! (validate-identity-hash identity-hash) err-invalid-input)
    
    (try! (stx-transfer? fee tx-sender contract-owner))
    
    (ok (map-set user-identities
      tx-sender
      {
        kyc-status: true,
        identity-hash: identity-hash,
        registration-time: stacks-block-height,
        is-certification-authority: false,
        staked-amount: u0
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
    (try! (check-owner))
    (asserts! (validate-proposal-input title description duration) err-invalid-input)
    
    ;; Update the current proposal ID
    (var-set current-proposal-id proposal-id)
    
    (ok (map-set proposals
      proposal-id
      {
        title: title,
        description: description,
        vote-count-yes: u0,
        vote-count-no: u0,
        end-block: (+ stacks-block-height duration),
        total-votes: u0
      }
    ))
  )
)

(define-public (cast-vote (proposal-id uint) (vote bool))
  (let
    (
      (proposal (unwrap! (map-get? proposals proposal-id) err-invalid-proposal))
      (vote-key {proposal-id: proposal-id, voter: tx-sender})
    )
    (asserts! (is-registered tx-sender) err-not-registered)
    (asserts! (< stacks-block-height (get end-block proposal)) err-voting-closed)
    (asserts! (not (default-to false (map-get? votes vote-key))) err-already-voted)
    
    (map-set votes vote-key true)
    (ok (map-set proposals proposal-id 
      (merge proposal 
        {
          vote-count-yes: (+ (get vote-count-yes proposal) (if vote u1 u0)),
          vote-count-no: (+ (get vote-count-no proposal) (if vote u0 u1)),
          total-votes: (+ (get total-votes proposal) u1)
        }
      )
    ))
  )
)

;; Staking and Certification Functions
(define-public (become-certification-authority)
  (let
    (
      (stake-amount (var-get minimum-certification-stake))
      (current-identity (unwrap! (map-get? user-identities tx-sender) err-not-registered))
    )
    (asserts! (is-registered tx-sender) err-not-registered)
    (asserts! (>= (stx-get-balance tx-sender) stake-amount) err-insufficient-stake)
    
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    (ok (map-set user-identities
      tx-sender
      (merge current-identity
        {
          is-certification-authority: true,
          staked-amount: stake-amount
        }
      )
    ))
  )
)

(define-public (issue-certification 
  (certified-user principal) 
  (certification-hash (string-utf8 64))
)
  (let
    (
      (authority-info (unwrap! (map-get? user-identities tx-sender) err-not-registered))
    )
    (asserts! (get is-certification-authority authority-info) err-not-certification-authority)
    (asserts! (is-registered certified-user) err-not-registered)
    (asserts! (validate-identity-hash certification-hash) err-invalid-input)
    
    (ok (map-set certifications
      {
        authority: tx-sender,
        certified-user: certified-user
      }
      {
        certification-hash: certification-hash,
        timestamp: stacks-block-height,
        is-disputed: false,
        dispute-votes-yes: u0,
        dispute-votes-no: u0
      }
    ))
  )
)

(define-public (dispute-certification (authority principal) (certified-user principal))
  (let
    (
      (cert-key {authority: authority, certified-user: certified-user})
      (certification (unwrap! (map-get? certifications cert-key) err-invalid-certification))
    )
    (asserts! (is-registered tx-sender) err-not-registered)
    (asserts! (validate-principal authority) err-invalid-input)
    (asserts! (validate-principal certified-user) err-invalid-input)
    (asserts! (not (get is-disputed certification)) err-certification-dispute)
    
    (map-set certification-disputes cert-key
      {
        dispute-start-block: stacks-block-height,
        total-dispute-votes: u0,
        is-resolved: false,
        dispute-votes-yes: u0,
        dispute-votes-no: u0
      }
    )
    
    (ok (map-set certifications cert-key
      (merge certification { is-disputed: true })
    ))
  )
)

(define-public (vote-on-certification-dispute
  (authority principal)
  (certified-user principal)
  (vote bool)
)
  (let
    (
      (cert-key {authority: authority, certified-user: certified-user})
      (authority-info (unwrap! (map-get? user-identities authority) err-not-registered))
      (dispute (unwrap! (map-get? certification-disputes cert-key) err-invalid-certification))
    )
    (asserts! (is-registered tx-sender) err-not-registered)
    (asserts! (validate-principal authority) err-invalid-input)
    (asserts! (validate-principal certified-user) err-invalid-input)
    (asserts! (not (get is-resolved dispute)) err-certification-dispute)
    
    (let
      (
        (updated-dispute (merge dispute 
          {
            total-dispute-votes: (+ (get total-dispute-votes dispute) u1),
            dispute-votes-yes: (+ (get dispute-votes-yes dispute) (if vote u1 u0)),
            dispute-votes-no: (+ (get dispute-votes-no dispute) (if vote u0 u1))
          }
        ))
      )
      (map-set certification-disputes cert-key updated-dispute)
      
      (if (>= (get total-dispute-votes updated-dispute) u10)
        (begin
          (if (> (get dispute-votes-yes updated-dispute) (get dispute-votes-no updated-dispute))
            (let
              (
                (slashing-amount (/ 
                  (* (get staked-amount authority-info) 
                     (var-get slashing-percentage)) 
                  u100
                ))
              )
              (try! (as-contract (stx-transfer? slashing-amount tx-sender contract-owner)))
              
              (map-set user-identities
                authority
                (merge authority-info {
                  staked-amount: (- (get staked-amount authority-info) slashing-amount)
                })
              )
            )
            true
          )
          
          (map-set certification-disputes cert-key
            (merge updated-dispute { is-resolved: true })
          )
        )
        true
      )
      
      (ok true)
    )
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

(define-read-only (get-certification-status 
  (authority principal) 
  (certified-user principal)
)
  (map-get? certifications 
    {
      authority: authority,
      certified-user: certified-user
    }
  )
)

(define-read-only (get-certification-authority-info (authority principal))
  (map-get? user-identities authority)
)

(define-read-only (get-minimum-stake)
  (var-get minimum-certification-stake)
)