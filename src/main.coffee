{ Address, crypto, Script, Transaction, PrivateKey } = require 'bitcore-lib'

# Number of random bytes provided by each party
NONCE_SIZE = 32

# Generate random keypairs for Alice and Bob
aliceKeyPair = new PrivateKey()
bobKeyPair = new PrivateKey()

# Alice and Bob each select a random bit
aliceValue = crypto.Random.getRandomBuffer(1)[0] & 0x01
bobValue = crypto.Random.getRandomBuffer(1)[0] & 0x01

# Encode this bit in their random buffer length
aliceRandom = crypto.Random.getRandomBuffer(NONCE_SIZE + aliceValue)
bobRandom = crypto.Random.getRandomBuffer(NONCE_SIZE + bobValue)

# The comments bellow follow the stack contents as the Bitcoin Script executes

redeemScript = Script()
.add('OP_2DUP')                                # Stack [A_rnd, B_rnd, A_rnd, B_rnd]
.add('OP_SHA256')                              # Stack [A_rnd, B_rnd, A_rnd, SHA256(B_rnd)]
.add(crypto.Hash.sha256(bobRandom))            # Stack [A_rnd, B_rnd, A_rnd, SHA256(B_rnd), SHA256(B_rnd)]
.add('OP_EQUALVERIFY')                         # Stack [A_rnd, B_rnd, A_rnd]
.add('OP_SHA256')                              # Stack [A_rnd, B_rnd, SHA256(A_rnd)]
.add(crypto.Hash.sha256(aliceRandom))          # Stack [A_rnd, B_rnd, SHA256(A_rnd), SHA256(A_rnd)]
.add('OP_EQUALVERIFY')                         # Stack [A_rnd, B_rnd]
.add('OP_SIZE')                                # Stack [A_rnd, B_rnd, SIZE(B_rnd)]
.add('OP_NIP')                                 # Stack [A_rnd, SIZE(B_rnd)]
.add(new Buffer([NONCE_SIZE]))                 # Stack [A_rnd, SIZE(B_rnd), NONCE_SIZE]
.add('OP_NUMEQUAL')                            # Stack [A_rnd, B_val]
.add('OP_SWAP')                                # Stack [B_val, A_rnd]
.add('OP_SIZE')                                # Stack [B_val, A_rnd, SIZE(A_rnd)]
.add('OP_NIP')                                 # Stack [B_val, SIZE(A_rnd)]
.add(new Buffer([NONCE_SIZE]))                 # Stack [B_val, SIZE(A_rnd), NONCE_SIZE]
.add('OP_NUMEQUAL')                            # Stack [B_val, A_val]
.add('OP_NUMEQUAL')                            # Stack [B_val === A_val ? 1 : 0]
.add('OP_IF')                                  # Stack []
.add(aliceKeyPair.toPublicKey().toBuffer())    # Stack [A_pub]
.add('OP_ELSE')                                # Stack []
.add(bobKeyPair.toPublicKey().toBuffer())      # Stack [B_pub]
.add('OP_ENDIF')                               # Stack []
.add('OP_CHECKSIG')                            # Stack []

p2shScriptPub = Script.buildScriptHashOut(redeemScript)

p2shAddress = p2shScriptPub.toAddress()

console.log('Alice and Bob should place their bets at', p2shAddress.toString())

# Assume a UTXO exists that sends 1BTC to the P2SH address calculated above.
# When this runs in production, this UTXO will have inputs from Alice and Bob,
# which is how they place their bets.
p2shUtxoWith1BTC =
	address: p2shAddress.toString()
	txId: 'a477af6b2667c29670467e4e0728b685ee07b240235771862318e29ddbe58458'
	outputIndex: 0
	script: p2shScriptPub.toString()
	satoshis: 1e8

# Now let's create a transaction that tries to spend the bet by suppliing the
# random values and Alice's signature

p2shScriptSig = Script().add(aliceRandom).add(bobRandom).add(redeemScript.toBuffer())

# XXX: bitcore doesn't support signing generic P2SH transactions. Find a manual
# way to do it
# tx = new Transaction()
# .from(p2shUtxoWith1BTC)
# .to(aliceKeyPair.toAddress(), 1e8)
# .applySignature(
# 	inputIndex: 0
# 	publicKey: null
# 	signature: null
# )

flags = Script.Interpreter.SCRIPT_VERIFY_P2SH
verified = Script.Interpreter().verify(p2shScriptSig, p2shScriptPub, null, 0, flags)

console.log('RESULT:', verified)
