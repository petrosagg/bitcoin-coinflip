{ crypto, util, Script, Transaction, PrivateKey } = require 'bitcore-lib'

# Number of random bytes provided by each party
NONCE_SIZE = 16

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
.add('OP_HASH160')                             # Stack [A_rnd, B_rnd, A_rnd, HASH160(B_rnd)]
.add(crypto.Hash.sha256ripemd160(bobRandom))   # Stack [A_rnd, B_rnd, A_rnd, HASH160(B_rnd), HASH160(B_rnd)]
.add('OP_EQUALVERIFY')                         # Stack [A_rnd, B_rnd, A_rnd]
.add('OP_HASH160')                             # Stack [A_rnd, B_rnd, HASH160(A_rnd)]
.add(crypto.Hash.sha256ripemd160(aliceRandom)) # Stack [A_rnd, B_rnd, HASH160(A_rnd), HASH160(A_rnd)]
.add('OP_EQUALVERIFY')                         # Stack [A_rnd, B_rnd]
.add('OP_SIZE')                                # Stack [A_rnd, B_rnd, SIZE(B_rnd)]
.add('OP_NIP')                                 # Stack [A_rnd, SIZE(B_rnd)]
.add(Buffer.from([ NONCE_SIZE ]))              # Stack [A_rnd, SIZE(B_rnd), NONCE_SIZE]
.add('OP_NUMEQUAL')                            # Stack [A_rnd, B_val]
.add('OP_SWAP')                                # Stack [B_val, A_rnd]
.add('OP_SIZE')                                # Stack [B_val, A_rnd, SIZE(A_rnd)]
.add('OP_NIP')                                 # Stack [B_val, SIZE(A_rnd)]
.add(Buffer.from([ NONCE_SIZE ]))              # Stack [B_val, SIZE(A_rnd), NONCE_SIZE]
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


# Assume a UTXO exists that sends 1BTC to the P2SH address calculated above.
# When this runs in production, this UTXO will have inputs from Alice and Bob,
# which is how they place their bets.
p2shUtxoWith1BTC = new Transaction.UnspentOutput(
	txId: 'a477af6b2667c29670467e4e0728b685ee07b240235771862318e29ddbe58458'
	outputIndex: 0
	script: p2shScriptPub
	satoshis: 1e8
)

console.log('Alice')
console.log('    Private Key:', aliceKeyPair.toWIF())
console.log('          Value:', aliceValue)
console.log('     Commitment:', aliceRandom.toString('hex'))
console.log('Bob')
console.log('    Private Key:', bobKeyPair.toWIF())
console.log('          Value:', bobValue)
console.log('     Commitment:', bobRandom.toString('hex'))
console.log('')
console.log('Funding address:', p2shAddress.toString())
console.log('')

# Calculate who won
if aliceValue is bobValue
	console.log('Alice wins')
	winnerKeyPair = aliceKeyPair
else
	console.log('Bob wins')
	winnerKeyPair = bobKeyPair

# Now let's create a transaction that tries to spend the bet
tx = new Transaction()
.from(p2shUtxoWith1BTC)
.to(winnerKeyPair.toAddress(), 1e8)

# Sign the transaction with Alice's private key
sigtype = crypto.Signature.SIGHASH_ALL
signature = Transaction.Sighash.sign(tx, winnerKeyPair, sigtype, 0, redeemScript)
signatureBuffer = Buffer.concat([ signature.toDER(), Buffer.from([ sigtype ]) ])

# Construct the sigScript containing the serialised redeemScript, the two
# random inputs and Alice's signature
p2shScriptSig = Script()
.add(signatureBuffer)
.add(aliceRandom)
.add(bobRandom)
.add(redeemScript.toBuffer())

interpreter = Script.Interpreter()
flags = Script.Interpreter.SCRIPT_VERIFY_P2SH
verified = interpreter.verify(p2shScriptSig, p2shScriptPub, tx, 0, flags)

console.log('Verifying spending transaction:', verified, interpreter.errstr)
