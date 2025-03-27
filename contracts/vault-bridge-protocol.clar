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

