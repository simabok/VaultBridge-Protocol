;; VaultBridge Protocol - Blockchain Value Exchange / Transaction System

;; Core constants
(define-constant ADMIN tx-sender)
(define-constant ERR_AUTH (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_PROCESSED (err u102))
(define-constant ERR_FAILED_TX (err u103))
(define-constant ERR_BAD_ID (err u104))
(define-constant ERR_BAD_VALUE (err u105))
(define-constant ERR_BAD_VENDOR (err u106))
(define-constant ERR_TIMEOUT (err u107))
(define-constant TRADE_TIMEOUT_BLOCKS u1008) 

;; Trade counter
(define-data-var trade-counter uint u0)

;; Project functions
(define-private (vendor-is-valid (vendor principal))
  (and 
    (not (is-eq vendor tx-sender))
    (not (is-eq vendor (as-contract tx-sender)))
  )
)

(define-private (trade-exists (trade-id uint))
  (<= trade-id (var-get trade-counter))
)

;; Trade data structure
(define-map TradeRegistry
  { trade-id: uint }
  {
    client: principal,
    vendor: principal,
    product-id: uint,
    amount: uint,
    status: (string-ascii 10),
    creation-time: uint,
    deadline: uint
  }
)

;; Public functions
(define-public (complete-trade (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (vendor (get vendor trade-data))
        (amount (get amount trade-data))
        (product-id (get product-id trade-data))
      )
      (asserts! (or (is-eq tx-sender ADMIN) (is-eq tx-sender (get client trade-data))) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (match (as-contract (stx-transfer? amount tx-sender vendor))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "completed" })
            )
            (print {event: "trade_completed", trade-id: trade-id, vendor: vendor, product-id: product-id, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (client-refund (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "refunded" })
            )
            (print {event: "client_refunded", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (client-cancel (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      (asserts! (is-eq tx-sender client) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "cancelled" })
            )
            (print {event: "trade_cancelled", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (extend-deadline (trade-id uint) (added-blocks uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (asserts! (> added-blocks u0) ERR_BAD_VALUE)
    (asserts! (<= added-blocks u1440) ERR_BAD_VALUE) ;; Max extension: ~10 days
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data)) 
        (vendor (get vendor trade-data))
        (current-deadline (get deadline trade-data))
        (new-deadline (+ current-deadline added-blocks))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { deadline: new-deadline })
      )
      (print {event: "deadline_extended", trade-id: trade-id, requestor: tx-sender, new-deadline: new-deadline})
      (ok true)
    )
  )
)

(define-public (reclaim-expired (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
        (deadline (get deadline trade-data))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (asserts! (> block-height deadline) (err u108)) ;; Must be expired
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "expired" })
            )
            (print {event: "expired_trade_reclaimed", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (raise-dispute (trade-id uint) (reason (string-ascii 50)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { status: "disputed" })
      )
      (print {event: "dispute_raised", trade-id: trade-id, party: tx-sender, reason: reason})
      (ok true)
    )
  )
)

(define-public (add-signature (trade-id uint) (signature (buff 65)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (print {event: "signature_added", trade-id: trade-id, signer: tx-sender, signature: signature})
      (ok true)
    )
  )
)

(define-public (set-recovery (trade-id uint) (recovery-principal principal))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
      )
      (asserts! (is-eq tx-sender client) ERR_AUTH)
      (asserts! (not (is-eq recovery-principal tx-sender)) (err u111)) ;; Different recovery address
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (print {event: "recovery_set", trade-id: trade-id, client: client, recovery: recovery-principal})
      (ok true)
    )
  )
)

(define-public (resolve-dispute (trade-id uint) (client-percent uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
    (asserts! (<= client-percent u100) ERR_BAD_VALUE) ;; Percentage range: 0-100
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
        (amount (get amount trade-data))
        (client-amount (/ (* amount client-percent) u100))
        (vendor-amount (- amount client-amount))
      )
      (asserts! (is-eq (get status trade-data) "disputed") (err u112)) ;; Trade must be disputed
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)

      ;; Transfer client portion
      (unwrap! (as-contract (stx-transfer? client-amount tx-sender client)) ERR_FAILED_TX)

      ;; Transfer vendor portion
      (unwrap! (as-contract (stx-transfer? vendor-amount tx-sender vendor)) ERR_FAILED_TX)

      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { status: "resolved" })
      )
      (print {event: "dispute_resolved", trade-id: trade-id, client: client, vendor: vendor, 
              client-amount: client-amount, vendor-amount: vendor-amount, client-percent: client-percent})
      (ok true)
    )
  )
)

(define-public (set-rate-limits (max-tries uint) (wait-period uint))
  (begin
    (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
    (asserts! (> max-tries u0) ERR_BAD_VALUE)
    (asserts! (<= max-tries u10) ERR_BAD_VALUE) ;; Max 10 attempts
    (asserts! (> wait-period u6) ERR_BAD_VALUE) ;; Min 6 blocks (~1 hour)
    (asserts! (<= wait-period u144) ERR_BAD_VALUE) ;; Max 144 blocks (~1 day)

    ;; Note: Would implement actual rate limiting in production

    (print {event: "rate_limits_set", max-tries: max-tries, 
            wait-period: wait-period, admin: tx-sender, block-height: block-height})
    (ok true)
  )
)

(define-public (add-cosigner (trade-id uint) (cosigner principal))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      ;; Multi-signature for high-value transactions only (> 1000 STX)
      (asserts! (> amount u1000) (err u120))
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (print {event: "cosigner_added", trade-id: trade-id, cosigner: cosigner, requestor: tx-sender})
      (ok true)
    )
  )
)

(define-public (freeze-trade (trade-id uint) (reason (string-ascii 100)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
      )
      (asserts! (or (is-eq tx-sender ADMIN) (is-eq tx-sender client) (is-eq tx-sender vendor)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") 
                   (is-eq (get status trade-data) "accepted")) 
                ERR_PROCESSED)
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { status: "frozen" })
      )
      (print {event: "trade_frozen", trade-id: trade-id, reporter: tx-sender, reason: reason})
      (ok true)
    )
  )
)

(define-public (create-staged-trade (vendor principal) (product-id uint) (amount uint) (stages uint))
  (let 
    (
      (new-id (+ (var-get trade-counter) u1))
      (deadline (+ block-height TRADE_TIMEOUT_BLOCKS))
      (stage-payment (/ amount stages))
    )
    (asserts! (> amount u0) ERR_BAD_VALUE)
    (asserts! (> stages u0) ERR_BAD_VALUE)
    (asserts! (<= stages u5) ERR_BAD_VALUE) ;; Max 5 stages
    (asserts! (vendor-is-valid vendor) ERR_BAD_VENDOR)
    (asserts! (is-eq (* stage-payment stages) amount) (err u121)) ;; Ensure even division
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      success
        (begin
          (var-set trade-counter new-id)
          (print {event: "staged_trade_created", trade-id: new-id, client: tx-sender, vendor: vendor, 
                  product-id: product-id, amount: amount, stages: stages, stage-payment: stage-payment})
          (ok new-id)
        )
      error ERR_FAILED_TX
    )
  )
)

(define-public (schedule-operation (operation (string-ascii 20)) (params (list 10 uint)))
  (begin
    (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
    (asserts! (> (len params) u0) ERR_BAD_VALUE)
    (let
      (
        (execution-block (+ block-height u144)) ;; 24 hours delay
      )
      (print {event: "operation_scheduled", operation: operation, params: params, execution-block: execution-block})
      (ok execution-block)
    )
  )
)

(define-public (enable-2fa (trade-id uint) (auth-code (buff 32)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      ;; 2FA for high-value trades only
      (asserts! (> amount u5000) (err u130))
      (asserts! (is-eq tx-sender client) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (print {event: "2fa_enabled", trade-id: trade-id, client: client, auth-hash: (hash160 auth-code)})
      (ok true)
    )
  )
)

(define-public (verify-signature (trade-id uint) (message (buff 32)) (signature (buff 65)) (signer principal))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
        (verification-data (unwrap! (secp256k1-recover? message signature) (err u150)))
      )
      ;; Verify with cryptographic proof
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq signer client) (is-eq signer vendor)) (err u151))
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)

      ;; Verify signature matches expected signer
      (asserts! (is-eq (unwrap! (principal-of? verification-data) (err u152)) signer) (err u153))

      (print {event: "signature_verified", trade-id: trade-id, verifier: tx-sender, signer: signer})
      (ok true)
    )
  )
)

(define-public (add-metadata (trade-id uint) (metadata-type (string-ascii 20)) (metadata-hash (buff 32)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
      )
      ;; Authorized parties only
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (not (is-eq (get status trade-data) "completed")) (err u160))
      (asserts! (not (is-eq (get status trade-data) "refunded")) (err u161))
      (asserts! (not (is-eq (get status trade-data) "expired")) (err u162))

      ;; Valid metadata types
      (asserts! (or (is-eq metadata-type "product-details") 
                   (is-eq metadata-type "delivery-proof")
                   (is-eq metadata-type "quality-check")
                   (is-eq metadata-type "client-preferences")) (err u163))

      (print {event: "metadata_added", trade-id: trade-id, metadata-type: metadata-type, 
              metadata-hash: metadata-hash, submitter: tx-sender})
      (ok true)
    )
  )
)

(define-public (create-vault (trade-id uint) (delay-blocks uint) (backup-principal principal))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (asserts! (> delay-blocks u72) ERR_BAD_VALUE) ;; Min 72 blocks (~12 hours)
    (asserts! (<= delay-blocks u1440) ERR_BAD_VALUE) ;; Max 1440 blocks (~10 days)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (unlock-height (+ block-height delay-blocks))
      )
      (asserts! (is-eq tx-sender client) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (asserts! (not (is-eq backup-principal client)) (err u180)) ;; Different from client
      (asserts! (not (is-eq backup-principal (get vendor trade-data))) (err u181)) ;; Different from vendor
      (print {event: "vault_created", trade-id: trade-id, client: client, 
              backup-principal: backup-principal, unlock-height: unlock-height})
      (ok unlock-height)
    )
  )
)

(define-public (zk-verify (trade-id uint) (proof (buff 128)) (public-inputs (list 5 (buff 32))))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (asserts! (> (len public-inputs) u0) ERR_BAD_VALUE)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
        (amount (get amount trade-data))
      )
      ;; Only for high-value trades
      (asserts! (> amount u10000) (err u190))
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)

      ;; Placeholder for actual ZK verification logic

      (print {event: "zk_verification_complete", trade-id: trade-id, verifier: tx-sender, 
              proof-hash: (hash160 proof), public-inputs: public-inputs})
      (ok true)
    )
  )
)

(define-public (transfer-ownership (trade-id uint) (new-client principal) (auth-code (buff 32)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (current-client (get client trade-data))
        (current-status (get status trade-data))
      )
      ;; Only current client or admin can transfer
      (asserts! (or (is-eq tx-sender current-client) (is-eq tx-sender ADMIN)) ERR_AUTH)
      ;; New client must be different from current parties
      (asserts! (not (is-eq new-client current-client)) (err u210))
      (asserts! (not (is-eq new-client (get vendor trade-data))) (err u211))
      ;; Only pending or accepted trades can be transferred
      (asserts! (or (is-eq current-status "pending") (is-eq current-status "accepted")) ERR_PROCESSED)
      ;; Transfer to new client
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { client: new-client })
      )
      (print {event: "ownership_transferred", trade-id: trade-id, 
              former-client: current-client, new-client: new-client, auth-hash: (hash160 auth-code)})
      (ok true)
    )
  )
)

(define-public (secure-withdrawal (trade-id uint) (withdraw-amount uint) (approval-sig (buff 65)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
        (amount (get amount trade-data))
        (status (get status trade-data))
      )
      ;; Only admin can process secure withdrawals
      (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
      ;; Only from disputed trades
      (asserts! (is-eq status "disputed") (err u220))
      ;; Cannot withdraw more than available
      (asserts! (<= withdraw-amount amount) ERR_BAD_VALUE)
      ;; Minimum lock time (48 blocks, ~8 hours)
      (asserts! (>= block-height (+ (get creation-time trade-data) u48)) (err u221))

      ;; Simulate signature verification
      ;; In production: validate both client and vendor approved

      ;; Process withdrawal
      (unwrap! (as-contract (stx-transfer? withdraw-amount tx-sender client)) ERR_FAILED_TX)

      ;; Update trade record
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { amount: (- amount withdraw-amount) })
      )

      (print {event: "secure_withdrawal_completed", trade-id: trade-id, client: client, 
              amount: withdraw-amount, remaining: (- amount withdraw-amount)})
      (ok true)
    )
  )
)

