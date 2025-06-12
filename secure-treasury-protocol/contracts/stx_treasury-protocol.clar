;; Multi-signature Treasury Management System
;; A comprehensive treasury management system with multi-signature controls

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-SIGNER (err u101))
(define-constant ERR-SIGNER-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-SIGNERS (err u103))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u104))
(define-constant ERR-PROPOSAL-EXPIRED (err u105))
(define-constant ERR-PROPOSAL-EXECUTED (err u106))
(define-constant ERR-ALREADY-VOTED (err u107))
(define-constant ERR-INSUFFICIENT-VOTES (err u108))
(define-constant ERR-INVALID-THRESHOLD (err u109))
(define-constant ERR-INSUFFICIENT-BALANCE (err u110))
(define-constant ERR-TRANSFER-FAILED (err u111))
(define-constant ERR-INVALID-AMOUNT (err u112))
(define-constant ERR-INVALID-RECIPIENT (err u113))
(define-constant ERR-PROPOSAL-ACTIVE (err u114))
(define-constant ERR-EMERGENCY-ACTIVE (err u115))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-SIGNERS u3)
(define-constant MAX-SIGNERS u20)
(define-constant PROPOSAL-DURATION u1440) ;; ~10 days in blocks (assuming 10 min blocks)

;; Data variables
(define-data-var signature-threshold uint u3)
(define-data-var total-signers uint u0)
(define-data-var proposal-nonce uint u0)
(define-data-var emergency-mode bool false)
(define-data-var treasury-balance uint u0)

;; Data maps
(define-map signers 
  principal 
  {
    is-active: bool,
    added-at: uint,
    added-by: principal
  }
)

(define-map proposals 
  uint 
  {
    proposer: principal,
    recipient: principal,
    amount: uint,
    description: (string-ascii 256),
    created-at: uint,
    expires-at: uint,
    executed: bool,
    votes-for: uint,
    votes-against: uint,
    proposal-type: (string-ascii 32) ;; "transfer", "add-signer", "remove-signer", "change-threshold"
  }
)

(define-map proposal-votes 
  {proposal-id: uint, signer: principal} 
  {
    vote: bool, ;; true = for, false = against
    voted-at: uint
  }
)

(define-map signer-proposals 
  uint 
  {
    target-signer: principal,
    new-threshold: uint
  }
)

;; Private functions

;; Check if caller is an active signer
(define-private (is-signer (user principal))
  (match (map-get? signers user)
    signer-info (get is-active signer-info)
    false
  )
)

;; Check if proposal has enough votes to pass
(define-private (has-sufficient-votes (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal-info
    (>= (get votes-for proposal-info) (var-get signature-threshold))
    false
  )
)

;; Check if proposal is still active (not expired and not executed)
(define-private (is-proposal-active (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal-info
    (and 
      (not (get executed proposal-info))
      (< stacks-block-height (get expires-at proposal-info))
    )
    false
  )
)

;; Get next proposal ID
(define-private (get-next-proposal-id)
  (let ((current-nonce (var-get proposal-nonce)))
    (var-set proposal-nonce (+ current-nonce u1))
    current-nonce
  )
)

;; Public functions

;; Initialize the treasury with initial signers
(define-public (initialize (initial-signers (list 20 principal)) (initial-threshold uint))
  (if (is-eq tx-sender CONTRACT-OWNER)
    (if (>= (len initial-signers) MIN-SIGNERS)
      (if (<= (len initial-signers) MAX-SIGNERS)
        (if (>= initial-threshold MIN-SIGNERS)
          (if (<= initial-threshold (len initial-signers))
            (begin
              ;; Add initial signers
              (fold add-initial-signer initial-signers true)
              
              ;; Set initial threshold and signer count
              (var-set signature-threshold initial-threshold)
              (var-set total-signers (len initial-signers))
              
              (ok true)
            )
            (err ERR-INVALID-THRESHOLD)
          )
          (err ERR-INVALID-THRESHOLD)
        )
        (err ERR-INSUFFICIENT-SIGNERS)
      )
      (err ERR-INSUFFICIENT-SIGNERS)
    )
    (err ERR-NOT-AUTHORIZED)
  )
)

;; Helper function for adding initial signers
(define-private (add-initial-signer (signer principal) (acc bool))
  (begin
    (map-set signers signer {
      is-active: true,
      added-at: stacks-block-height,
      added-by: CONTRACT-OWNER
    })
    acc
  )
)

;; Create a transfer proposal
(define-public (create-transfer-proposal (recipient principal) (amount uint) (description (string-ascii 256)))
  (let ((proposal-id (get-next-proposal-id)))
    (if (is-signer tx-sender)
      (if (not (var-get emergency-mode))
        (if (> amount u0)
          (if (not (is-eq recipient tx-sender))
            (if (<= amount (var-get treasury-balance))
              (begin
                (map-set proposals proposal-id {
                  proposer: tx-sender,
                  recipient: recipient,
                  amount: amount,
                  description: description,
                  created-at: stacks-block-height,
                  expires-at: (+ stacks-block-height PROPOSAL-DURATION),
                  executed: false,
                  votes-for: u0,
                  votes-against: u0,
                  proposal-type: "transfer"
                })
                (ok proposal-id)
              )
              (err ERR-INSUFFICIENT-BALANCE)
            )
            (err ERR-INVALID-RECIPIENT)
          )
          (err ERR-INVALID-AMOUNT)
        )
        (err ERR-EMERGENCY-ACTIVE)
      )
      (err ERR-NOT-AUTHORIZED)
    )
  )
)

;; Create a proposal to add a new signer
(define-public (create-add-signer-proposal (new-signer principal) (description (string-ascii 256)))
  (let ((proposal-id (get-next-proposal-id)))
    (if (is-signer tx-sender)
      (if (not (var-get emergency-mode))
        (if (not (is-signer new-signer))
          (if (< (var-get total-signers) MAX-SIGNERS)
            (begin
              (map-set proposals proposal-id {
                proposer: tx-sender,
                recipient: new-signer,
                amount: u0,
                description: description,
                created-at: stacks-block-height,
                expires-at: (+ stacks-block-height PROPOSAL-DURATION),
                executed: false,
                votes-for: u0,
                votes-against: u0,
                proposal-type: "add-signer"
              })
              
              (map-set signer-proposals proposal-id {
                target-signer: new-signer,
                new-threshold: u0
              })
              
              (ok proposal-id)
            )
            (err ERR-INSUFFICIENT-SIGNERS)
          )
          (err ERR-SIGNER-EXISTS)
        )
        (err ERR-EMERGENCY-ACTIVE)
      )
      (err ERR-NOT-AUTHORIZED)
    )
  )
)

;; Create a proposal to remove a signer
(define-public (create-remove-signer-proposal (target-signer principal) (description (string-ascii 256)))
  (let ((proposal-id (get-next-proposal-id)))
    (if (is-signer tx-sender)
      (if (not (var-get emergency-mode))
        (if (is-signer target-signer)
          (if (not (is-eq target-signer tx-sender))
            (if (> (var-get total-signers) MIN-SIGNERS)
              (begin
                (map-set proposals proposal-id {
                  proposer: tx-sender,
                  recipient: target-signer,
                  amount: u0,
                  description: description,
                  created-at: stacks-block-height,
                  expires-at: (+ stacks-block-height PROPOSAL-DURATION),
                  executed: false,
                  votes-for: u0,
                  votes-against: u0,
                  proposal-type: "remove-signer"
                })
                
                (map-set signer-proposals proposal-id {
                  target-signer: target-signer,
                  new-threshold: u0
                })
                
                (ok proposal-id)
              )
              (err ERR-INSUFFICIENT-SIGNERS)
            )
            (err ERR-INVALID-SIGNER)
          )
          (err ERR-INVALID-SIGNER)
        )
        (err ERR-EMERGENCY-ACTIVE)
      )
      (err ERR-NOT-AUTHORIZED)
    )
  )
)

;; Create a proposal to change signature threshold
(define-public (create-threshold-proposal (new-threshold uint) (description (string-ascii 256)))
  (let ((proposal-id (get-next-proposal-id)))
    (if (is-signer tx-sender)
      (if (not (var-get emergency-mode))
        (if (>= new-threshold MIN-SIGNERS)
          (if (<= new-threshold (var-get total-signers))
            (if (not (is-eq new-threshold (var-get signature-threshold)))
              (begin
                (map-set proposals proposal-id {
                  proposer: tx-sender,
                  recipient: tx-sender,
                  amount: new-threshold,
                  description: description,
                  created-at: stacks-block-height,
                  expires-at: (+ stacks-block-height PROPOSAL-DURATION),
                  executed: false,
                  votes-for: u0,
                  votes-against: u0,
                  proposal-type: "change-threshold"
                })
                
                (map-set signer-proposals proposal-id {
                  target-signer: tx-sender,
                  new-threshold: new-threshold
                })
                
                (ok proposal-id)
              )
              (err ERR-INVALID-THRESHOLD)
            )
            (err ERR-INVALID-THRESHOLD)
          )
          (err ERR-INVALID-THRESHOLD)
        )
        (err ERR-EMERGENCY-ACTIVE)
      )
      (err ERR-NOT-AUTHORIZED)
    )
  )
)

;; Vote on a proposal
(define-public (vote-on-proposal (proposal-id uint) (vote bool))
  (match (map-get? proposals proposal-id)
    proposal
    (let ((vote-key {proposal-id: proposal-id, signer: tx-sender}))
      (if (is-signer tx-sender)
        (if (is-proposal-active proposal-id)
          (if (is-none (map-get? proposal-votes vote-key))
            (begin
              ;; Record the vote
              (map-set proposal-votes vote-key {
                vote: vote,
                voted-at: stacks-block-height
              })
              
              ;; Update proposal vote counts
              (map-set proposals proposal-id (merge proposal {
                votes-for: (if vote (+ (get votes-for proposal) u1) (get votes-for proposal)),
                votes-against: (if vote (get votes-against proposal) (+ (get votes-against proposal) u1))
              }))
              
              (ok true)
            )
            (err ERR-ALREADY-VOTED)
          )
          (err ERR-PROPOSAL-EXPIRED)
        )
        (err ERR-NOT-AUTHORIZED)
      )
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Execute a proposal that has sufficient votes
(define-public (execute-proposal (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal
    (if (is-signer tx-sender)
      (if (not (get executed proposal))
        (if (has-sufficient-votes proposal-id)
          (if (< stacks-block-height (get expires-at proposal))
            (begin
              ;; Mark proposal as executed
              (map-set proposals proposal-id (merge proposal {executed: true}))
              
              ;; Execute based on proposal type
              (if (is-eq (get proposal-type proposal) "transfer")
                (execute-transfer-proposal proposal)
                (if (is-eq (get proposal-type proposal) "add-signer")
                  (execute-add-signer-proposal proposal-id)
                  (if (is-eq (get proposal-type proposal) "remove-signer")
                    (execute-remove-signer-proposal proposal-id)
                    (if (is-eq (get proposal-type proposal) "change-threshold")
                      (execute-threshold-proposal proposal-id)
                      (err ERR-PROPOSAL-NOT-FOUND)
                    )
                  )
                )
              )
            )
            (err ERR-PROPOSAL-EXPIRED)
          )
          (err ERR-INSUFFICIENT-VOTES)
        )
        (err ERR-PROPOSAL-EXECUTED)
      )
      (err ERR-NOT-AUTHORIZED)
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Execute transfer proposal
(define-private (execute-transfer-proposal (proposal {proposer: principal, recipient: principal, amount: uint, description: (string-ascii 256), created-at: uint, expires-at: uint, executed: bool, votes-for: uint, votes-against: uint, proposal-type: (string-ascii 32)}))
  (let ((amount (get amount proposal))
        (recipient (get recipient proposal)))
    (if (<= amount (var-get treasury-balance))
      ;; Transfer STX from contract to recipient
      (match (as-contract (stx-transfer? amount tx-sender recipient))
        success (begin
          (var-set treasury-balance (- (var-get treasury-balance) amount))
          (ok true)
        )
        error (err ERR-TRANSFER-FAILED)
      )
      (err ERR-INSUFFICIENT-BALANCE)
    )
  )
)

;; Execute add signer proposal
(define-private (execute-add-signer-proposal (proposal-id uint))
  (match (map-get? signer-proposals proposal-id)
    signer-info (begin
      (map-set signers (get target-signer signer-info) {
        is-active: true,
        added-at: stacks-block-height,
        added-by: tx-sender
      })
      (var-set total-signers (+ (var-get total-signers) u1))
      (ok true)
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Execute remove signer proposal
(define-private (execute-remove-signer-proposal (proposal-id uint))
  (match (map-get? signer-proposals proposal-id)
    signer-info (begin
      (map-set signers (get target-signer signer-info) {
        is-active: false,
        added-at: stacks-block-height,
        added-by: tx-sender
      })
      (var-set total-signers (- (var-get total-signers) u1))
      
      ;; Adjust threshold if necessary
      (if (> (var-get signature-threshold) (var-get total-signers))
        (var-set signature-threshold (var-get total-signers))
        true
      )
      (ok true)
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Execute threshold change proposal
(define-private (execute-threshold-proposal (proposal-id uint))
  (match (map-get? signer-proposals proposal-id)
    signer-info (begin
      (var-set signature-threshold (get new-threshold signer-info))
      (ok true)
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Deposit STX to treasury
(define-public (deposit-to-treasury (amount uint))
  (if (> amount u0)
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      success (begin
        (var-set treasury-balance (+ (var-get treasury-balance) amount))
        (ok true)
      )
      error (err ERR-TRANSFER-FAILED)
    )
    (err ERR-INVALID-AMOUNT)
  )
)

;; Emergency functions (only contract owner)
(define-public (activate-emergency-mode)
  (if (is-eq tx-sender CONTRACT-OWNER)
    (begin
      (var-set emergency-mode true)
      (ok true)
    )
    (err ERR-NOT-AUTHORIZED)
  )
)

(define-public (deactivate-emergency-mode)
  (if (is-eq tx-sender CONTRACT-OWNER)
    (begin
      (var-set emergency-mode false)
      (ok true)
    )
    (err ERR-NOT-AUTHORIZED)
  )
)

;; Emergency withdrawal (only in emergency mode)
(define-public (emergency-withdraw (amount uint) (recipient principal))
  (if (is-eq tx-sender CONTRACT-OWNER)
    (if (var-get emergency-mode)
      (if (<= amount (var-get treasury-balance))
        (match (as-contract (stx-transfer? amount tx-sender recipient))
          success (begin
            (var-set treasury-balance (- (var-get treasury-balance) amount))
            (ok true)
          )
          error (err ERR-TRANSFER-FAILED)
        )
        (err ERR-INSUFFICIENT-BALANCE)
      )
      (err ERR-NOT-AUTHORIZED)
    )
    (err ERR-NOT-AUTHORIZED)
  )
)

;; Cancel proposal (only proposer, only if not executed and still active)
(define-public (cancel-proposal (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal
    (if (is-eq tx-sender (get proposer proposal))
      (if (not (get executed proposal))
        (if (is-proposal-active proposal-id)
          (begin
            ;; Mark proposal as expired by setting expires-at to current block
            (map-set proposals proposal-id (merge proposal {
              expires-at: stacks-block-height
            }))
            (ok true)
          )
          (err ERR-PROPOSAL-EXPIRED)
        )
        (err ERR-PROPOSAL-EXECUTED)
      )
      (err ERR-NOT-AUTHORIZED)
    )
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Read-only functions

;; Get signer information
(define-read-only (get-signer-info (signer principal))
  (map-get? signers signer)
)

;; Get proposal information
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id)
)

;; Get proposal vote
(define-read-only (get-proposal-vote (proposal-id uint) (signer principal))
  (map-get? proposal-votes {proposal-id: proposal-id, signer: signer})
)

;; Get signer proposal details
(define-read-only (get-signer-proposal (proposal-id uint))
  (map-get? signer-proposals proposal-id)
)

;; Get treasury status
(define-read-only (get-treasury-status)
  (ok {
    balance: (var-get treasury-balance),
    total-signers: (var-get total-signers),
    signature-threshold: (var-get signature-threshold),
    emergency-mode: (var-get emergency-mode),
    proposal-nonce: (var-get proposal-nonce)
  })
)

;; Check if user is a signer
(define-read-only (is-active-signer (user principal))
  (is-signer user)
)

;; Get proposal status
(define-read-only (get-proposal-status (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal
    (ok {
      is-active: (is-proposal-active proposal-id),
      has-sufficient-votes: (has-sufficient-votes proposal-id),
      votes-needed: (if (>= (get votes-for proposal) (var-get signature-threshold))
                      u0
                      (- (var-get signature-threshold) (get votes-for proposal))),
      time-remaining: (if (> (get expires-at proposal) stacks-block-height)
                        (- (get expires-at proposal) stacks-block-height)
                        u0)
    })
    (err ERR-PROPOSAL-NOT-FOUND)
  )
)

;; Get all active signers (simplified - returns first 20)
(define-read-only (get-signature-threshold)
  (ok (var-get signature-threshold))
)

;; Get total signers count
(define-read-only (get-total-signers)
  (ok (var-get total-signers))
)

;; Get treasury balance
(define-read-only (get-treasury-balance)
  (ok (var-get treasury-balance))
)

;; Check if emergency mode is active
(define-read-only (is-emergency-mode)
  (ok (var-get emergency-mode))
)
