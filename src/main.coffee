crypto = require 'crypto'
{Address, Script, Key, ScriptInterpreter, TransactionBuilder} = require 'bitcore'

# Number of random bytes provided by each party
NONCE_SIZE = 32

# Helper functions for the script building bellow
pushData = (data) ->
    "0x#{new Buffer([data.length]).toString('hex')} 0x#{data.toString('hex')}"

sha256 = (buffer) ->
    crypto.createHash('sha256').update(buffer).digest()

# Generate random keypairs for Alice and Bob
aliceKeyPair = Key.generateSync()
bobKeyPair = Key.generateSync()

# Alice and Bob each select a random bit
aliceValue = crypto.randomBytes(1)[0] & 0x01
bobValue = crypto.randomBytes(1)[0] & 0x01

# Encode this bit in their random buffer length
aliceRandom = crypto.randomBytes(NONCE_SIZE + aliceValue)
bobRandom = crypto.randomBytes(NONCE_SIZE + bobValue)

# The comments bellow follow the stack contents as the Bitcoin Script executes

scriptSig = [                              # Stack []
    pushData(aliceRandom)                    # Stack [A_sig]
    pushData(aliceRandom)                  # Stack [A_sig, A_rnd]
    pushData(bobRandom)                    # Stack [A_sig, A_rnd, B_rnd]
].join(' ')

scriptPubKey = [
    '2DUP'                                 # Stack [A_sig, A_rnd, B_rnd, A_rnd, B_rnd]
    'SHA256'                               # Stack [A_sig, A_rnd, B_rnd, A_rnd, SHA256(B_rnd)]
    pushData(sha256(bobRandom))            # Stack [A_sig, A_rnd, B_rnd, A_rnd, SHA256(B_rnd), SHA256(B_rnd)]
    'EQUALVERIFY'                          # Stack [A_sig, A_rnd, B_rnd, A_rnd]
    'SHA256'                               # Stack [A_sig, A_rnd, B_rnd, SHA256(A_rnd)]
    pushData(sha256(aliceRandom))          # Stack [A_sig, A_rnd, B_rnd, SHA256(A_rnd), SHA256(A_rnd)]
    'EQUALVERIFY'                          # Stack [A_sig, A_rnd, B_rnd]
    'SIZE'                                 # Stack [A_sig, A_rnd, B_rnd, SIZE(B_rnd)]
    'NIP'                                  # Stack [A_sig, A_rnd, SIZE(B_rnd)]
    pushData(new Buffer([NONCE_SIZE]))     # Stack [A_sig, A_rnd, SIZE(B_rnd), NONCE_SIZE]
    'NUMEQUAL'                             # Stack [A_sig, A_rnd, B_val]
    'SWAP'                                 # Stack [A_sig, B_val, A_rnd]
    'SIZE'                                 # Stack [A_sig, B_val, A_rnd, SIZE(A_rnd)]
    'NIP'                                  # Stack [A_sig, B_val, SIZE(A_rnd)]
    pushData(new Buffer([NONCE_SIZE]))     # Stack [A_sig, B_val, SIZE(A_rnd), NONCE_SIZE]
    'NUMEQUAL'                             # Stack [A_sig, B_val, A_val]
    'NUMEQUAL'                             # Stack [A_sig, B_val === A_val ? 1 : 0]
    'IF'                                   # Stack [A_sig, ]
        pushData(aliceKeyPair.public)      # Stack [A_sig, A_pub]
    'ELSE'                                 # Stack [A_sig, A_pub]
        pushData(bobKeyPair.public)        # Stack [A_sig, A_pub]
    'ENDIF'                                # Stack [A_sig, A_pub]
    'CHECKSIG'                             # Stack [true]
].join(' ')

console.log('== scriptSig ==')
console.log(scriptSig)

console.log('== scriptPubKey ==')
console.log(scriptPubKey)
 
# Create the script buffers from the human readable form above
scriptSig = Script.fromHumanReadable(scriptSig)
scriptPubKey = Script.fromHumanReadable(scriptPubKey)

# Calculate the P2SH address for our redeem script
addr = Address.fromScript(scriptPubKey, 'testnet')

info = TransactionBuilder.infoForP2sh(address: addr.as('base58'), 'testnet')
p2shScript = info.scriptBufHex
p2shAddress = info.address

utxos = [
    {
        # address: 'n2hoFVbPrYQf7RJwiRy1tkbuPPqyhAEfbp'
        txid: 'e4bc22d8c519d3cf848d710619f8480be56176a4a6548dfbe865ab3886b578b5'
        vout: 0
        ts: 1396290442
        scriptPubKey: scriptPubKey.serialize().toString('hex')
        amount: 2
        confirmations: 7
  }
]

outs = [
    {
        address: info.address
        amount: 1.9
    }
]

tx = new TransactionBuilder()
    .setUnspent(utxos)
    .setOutputs(outs)
    .sign([aliceKeyPair.private])
    .build()

interpreter = new ScriptInterpreter(verifyP2SH: true)

# Run the two scripts
interpreter.evalTwo(scriptSig, scriptPubKey, tx, 0, 0x01, (err) ->
    if err
        console.log('Script failed:', err)
)
console.log('P2SH Address:', addr.as('base58'))
