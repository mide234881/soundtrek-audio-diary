;; soundtrek-core
;; 
;; This contract serves as the central registry for SoundTrek audio recordings,
;; managing associations between audio content (IPFS), geographic coordinates,
;; and creator ownership. It enables registration, discovery, and management
;; of location-based audio content on the Stacks blockchain.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-RECORDING-NOT-FOUND (err u101))
(define-constant ERR-INVALID-COORDINATES (err u102))
(define-constant ERR-INVALID-METADATA (err u103))
(define-constant ERR-DUPLICATE-RECORDING (err u104))
(define-constant ERR-INVALID-PRIVACY-RADIUS (err u105))
(define-constant ERR-RECORDING-LOCKED (err u106))

;; Constants
(define-constant MAX-PRIVACY-RADIUS u1000) ;; Maximum privacy radius in meters
(define-constant MIN-TITLE-LENGTH u3) ;; Minimum length for recording title
(define-constant MAX-TITLE-LENGTH u100) ;; Maximum length for recording title
(define-constant MAX-DESCRIPTION-LENGTH u500) ;; Maximum length for description

;; Data structures
(define-map recordings
  { recording-id: (buff 36) } ;; UUID as byte buffer
  {
    creator: principal,
    title: (string-utf8 100),
    description: (string-utf8 500),
    ipfs-hash: (string-ascii 64),
    latitude: int,  ;; Stored as integer with 6 decimal precision (multiply by 1,000,000)
    longitude: int, ;; Stored as integer with 6 decimal precision (multiply by 1,000,000)
    privacy-radius: uint, ;; Radius in meters where location is obscured
    timestamp: uint, ;; Unix timestamp of creation
    tags: (list 10 (string-utf8 30)), ;; Up to 10 tags, 30 characters each
    is-locked: bool ;; If true, recording cannot be modified
  }
)

(define-map recording-ownership
  { recording-id: (buff 36) }
  { owner: principal }
)

;; Recording counter for tracking total recordings in the system
(define-data-var recording-count uint u0)

;; Principal to list of recording IDs for quick lookup
(define-map creator-recordings
  { creator: principal }
  { recording-ids: (list 1000 (buff 36)) }
)

;; Maps geographic cell to recording IDs for location-based discovery
;; Grid cells are approximately 1km x 1km (0.01 degree resolution)
(define-map geo-index
  { lat-index: int, lng-index: int }
  { recording-ids: (list 1000 (buff 36)) }
)

;; Private functions

;; Calculate geographic index for a given coordinate
;; Converts precise coordinates to grid cell for geo-indexing
(define-private (calculate-geo-index (lat int) (lng int))
  {
    lat-index: (/ lat (* u1 u100000)), ;; Divide by 100,000 to get 0.01 degree resolution
    lng-index: (/ lng (* u1 u100000))
  }
)

;; Add recording ID to creator's list of recordings
(define-private (add-to-creator-recordings (recording-id (buff 36)) (creator principal))
  (let (
    (current-recordings (default-to { recording-ids: (list) } (map-get? creator-recordings { creator: creator })))
    (updated-recordings (unwrap-panic (as-max-len? (append (get recording-ids current-recordings) recording-id) u1000)))
  )
  (map-set creator-recordings { creator: creator } { recording-ids: updated-recordings })
  (ok true))
)

;; Add recording ID to geographic index for location-based discovery
(define-private (add-to-geo-index (recording-id (buff 36)) (lat int) (lng int))
  (let (
    (geo-idx (calculate-geo-index lat lng))
    (current-cell (default-to { recording-ids: (list) } 
                  (map-get? geo-index { lat-index: (get lat-index geo-idx), lng-index: (get lng-index geo-idx) })))
    (updated-cell (unwrap-panic (as-max-len? (append (get recording-ids current-cell) recording-id) u1000)))
  )
  (map-set geo-index 
    { lat-index: (get lat-index geo-idx), lng-index: (get lng-index geo-idx) } 
    { recording-ids: updated-cell })
  (ok true))
)

;; Validate coordinates are within acceptable range (-90 to 90 for lat, -180 to 180 for lng)
(define-private (validate-coordinates (lat int) (lng int))
  (and 
    (and (>= lat (* (- u90) u1000000)) (<= lat (* u90 u1000000)))
    (and (>= lng (* (- u180) u1000000)) (<= lng (* u180 u1000000)))
  )
)

;; Validate recording metadata meets platform requirements
(define-private (validate-metadata (title (string-utf8 100)) (description (string-utf8 500)))
  (and
    (>= (len title) MIN-TITLE-LENGTH)
    (<= (len title) MAX-TITLE-LENGTH)
    (<= (len description) MAX-DESCRIPTION_LENGTH)
  )
)

;; Public functions

;; Register a new audio recording with location data
(define-public (register-recording 
  (recording-id (buff 36))
  (title (string-utf8 100))
  (description (string-utf8 500))
  (ipfs-hash (string-ascii 64))
  (latitude int)
  (longitude int)
  (privacy-radius uint)
  (tags (list 10 (string-utf8 30)))
)
  (let (
    (caller tx-sender)
    (timestamp (unwrap-panic (get-block-info? time u0)))
  )
    ;; Validate inputs
    (asserts! (validate-coordinates latitude longitude) ERR-INVALID-COORDINATES)
    (asserts! (validate-metadata title description) ERR-INVALID-METADATA)
    (asserts! (<= privacy-radius MAX-PRIVACY-RADIUS) ERR-INVALID-PRIVACY-RADIUS)
    (asserts! (is-none (map-get? recordings { recording-id: recording-id })) ERR-DUPLICATE-RECORDING)
    
    ;; Store recording data
    (map-set recordings 
      { recording-id: recording-id }
      {
        creator: caller,
        title: title,
        description: description,
        ipfs-hash: ipfs-hash,
        latitude: latitude,
        longitude: longitude,
        privacy-radius: privacy-radius,
        timestamp: timestamp,
        tags: tags,
        is-locked: false
      }
    )
    
    ;; Set initial ownership
    (map-set recording-ownership { recording-id: recording-id } { owner: caller })
    
    ;; Update indexes
    (try! (add-to-creator-recordings recording-id caller))
    (try! (add-to-geo-index recording-id latitude longitude))
    
    ;; Increment recording count
    (var-set recording-count (+ (var-get recording-count) u1))
    
    (ok recording-id)
  )
)

;; Update an existing recording's metadata (only by owner/creator)
(define-public (update-recording-metadata
  (recording-id (buff 36))
  (title (string-utf8 100))
  (description (string-utf8 500))
  (tags (list 10 (string-utf8 30)))
)
  (let (
    (caller tx-sender)
    (recording-opt (map-get? recordings { recording-id: recording-id }))
  )
    ;; Check recording exists and caller is owner
    (asserts! (is-some recording-opt) ERR-RECORDING-NOT-FOUND)
    (let (
      (recording (unwrap-panic recording-opt))
    )
      (asserts! (is-eq (get creator recording) caller) ERR-NOT-AUTHORIZED)
      (asserts! (not (get is-locked recording)) ERR-RECORDING-LOCKED)
      (asserts! (validate-metadata title description) ERR-INVALID-METADATA)
      
      ;; Update metadata
      (map-set recordings 
        { recording-id: recording-id }
        (merge recording {
          title: title,
          description: description,
          tags: tags
        })
      )
      
      (ok true)
    )
  )
)

;; Update a recording's privacy settings
(define-public (update-privacy
  (recording-id (buff 36))
  (privacy-radius uint)
)
  (let (
    (caller tx-sender)
    (recording-opt (map-get? recordings { recording-id: recording-id }))
  )
    ;; Check recording exists and caller is owner
    (asserts! (is-some recording-opt) ERR-RECORDING-NOT-FOUND)
    (let (
      (recording (unwrap-panic recording-opt))
    )
      (asserts! (is-eq (get creator recording) caller) ERR-NOT-AUTHORIZED)
      (asserts! (not (get is-locked recording)) ERR-RECORDING-LOCKED)
      (asserts! (<= privacy-radius MAX-PRIVACY-RADIUS) ERR-INVALID-PRIVACY-RADIUS)
      
      ;; Update privacy radius
      (map-set recordings 
        { recording-id: recording-id }
        (merge recording {
          privacy-radius: privacy-radius
        })
      )
      
      (ok true)
    )
  )
)

;; Lock a recording to prevent further modifications (permanent)
(define-public (lock-recording
  (recording-id (buff 36))
)
  (let (
    (caller tx-sender)
    (recording-opt (map-get? recordings { recording-id: recording-id }))
  )
    ;; Check recording exists and caller is owner
    (asserts! (is-some recording-opt) ERR-RECORDING-NOT-FOUND)
    (let (
      (recording (unwrap-panic recording-opt))
    )
      (asserts! (is-eq (get creator recording) caller) ERR-NOT-AUTHORIZED)
      
      ;; Lock the recording
      (map-set recordings 
        { recording-id: recording-id }
        (merge recording {
          is-locked: true
        })
      )
      
      (ok true)
    )
  )
)

;; Transfer ownership of a recording
(define-public (transfer-ownership
  (recording-id (buff 36))
  (new-owner principal)
)
  (let (
    (caller tx-sender)
    (ownership-opt (map-get? recording-ownership { recording-id: recording-id }))
  )
    ;; Check recording exists and caller is current owner
    (asserts! (is-some ownership-opt) ERR-RECORDING-NOT-FOUND)
    (asserts! (is-eq (get owner (unwrap-panic ownership-opt)) caller) ERR-NOT-AUTHORIZED)
    
    ;; Transfer ownership
    (map-set recording-ownership { recording-id: recording-id } { owner: new-owner })
    
    (ok true)
  )
)

;; Read-only functions

;; Get recording details by ID
(define-read-only (get-recording (recording-id (buff 36)))
  (map-get? recordings { recording-id: recording-id })
)

;; Get recording owner
(define-read-only (get-recording-owner (recording-id (buff 36)))
  (map-get? recording-ownership { recording-id: recording-id })
)

;; Get recordings by creator
(define-read-only (get-recordings-by-creator (creator principal))
  (default-to { recording-ids: (list) } (map-get? creator-recordings { creator: creator }))
)

;; Get total number of recordings in the system
(define-read-only (get-recording-count)
  (var-get recording-count)
)

;; Get recordings in a geographic cell for location-based discovery
(define-read-only (get-recordings-by-location (latitude int) (longitude int))
  (let (
    (geo-idx (calculate-geo-index latitude longitude))
  )
    (default-to { recording-ids: (list) } 
      (map-get? geo-index { 
        lat-index: (get lat-index geo-idx), 
        lng-index: (get lng-index geo-idx) 
      })
    )
  )
)

;; Check if user is authorized to modify a recording
(define-read-only (is-authorized-modifier (recording-id (buff 36)) (user principal))
  (let (
    (ownership-opt (map-get? recording-ownership { recording-id: recording-id }))
  )
    (if (is-some ownership-opt)
      (is-eq (get owner (unwrap-panic ownership-opt)) user)
      false
    )
  )
)