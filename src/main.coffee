crypto = require 'crypto'
{Address, Script, Key, ScriptInterpreter} = require 'bitcore'

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
	pushData(aliceRandom)                  # Stack [A_rnd]
	pushData(bobRandom)                    # Stack [A_rnd, B_rnd]
].join(' ')

scriptPubKey = [
	'2DUP'                                 # Stack [A_rnd, B_rnd, A_rnd, B_rnd]
	'SHA256'                               # Stack [A_rnd, B_rnd, A_rnd, SHA256(B_rnd)]
	pushData(sha256(bobRandom))            # Stack [A_rnd, B_rnd, A_rnd, SHA256(B_rnd), SHA256(B_rnd)]
	'EQUALVERIFY'                          # Stack [A_rnd, B_rnd, A_rnd]
	'SHA256'                               # Stack [A_rnd, B_rnd, SHA256(A_rnd)]
	pushData(sha256(aliceRandom))          # Stack [A_rnd, B_rnd, SHA256(A_rnd), SHA256(A_rnd)]
	'EQUALVERIFY'                          # Stack [A_rnd, B_rnd]
	'SIZE'                                 # Stack [A_rnd, B_rnd, SIZE(B_rnd)]
	'NIP'                                  # Stack [A_rnd, SIZE(B_rnd)]
	pushData(new Buffer([NONCE_SIZE]))     # Stack [A_rnd, SIZE(B_rnd), NONCE_SIZE]
	'NUMEQUAL'                             # Stack [A_rnd, B_val]
	'SWAP'                                 # Stack [B_val, A_rnd]
	'SIZE'                                 # Stack [B_val, A_rnd, SIZE(A_rnd)]
	'NIP'                                  # Stack [B_val, SIZE(A_rnd)]
	pushData(new Buffer([NONCE_SIZE]))     # Stack [B_val, SIZE(A_rnd), NONCE_SIZE]
	'NUMEQUAL'                             # Stack [B_val, A_val]
	'NUMEQUAL'                             # Stack [B_val === A_val ? 1 : 0]
	'IF'                                   # Stack []
		pushData(aliceKeyPair.public)      # Stack [A_pub]
	'ELSE'                                 # Stack []
		pushData(bobKeyPair.public)        # Stack [B_pub]
	'ENDIF'                                # Stack []
	'CHECKSIG'                             # Stack []
].join(' ')

console.log('== scriptSig ==')
console.log(scriptSig)

console.log('== scriptPubKey ==')
console.log(scriptPubKey)
 
# Create the script buffers from the human readable form above
scriptSig = Script.fromHumanReadable(scriptSig)
scriptPubKey = Script.fromHumanReadable(scriptPubKey)

interpreter = new ScriptInterpreter(verifyP2SH: true)

# Run the two scripts
interpreter.evalTwo(scriptSig, scriptPubKey, null, 0, null, (err) ->
	if err
		console.log('Script failed:', err)
)

# Calculate the P2SH address for our redeem script
addr = Address.fromScript(scriptPubKey, 'testnet')
console.log('P2SH Address:', addr.as('base58'))
