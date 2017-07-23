bitcoin = require 'bitcoinjs-lib'
crypto = require 'crypto'
{ crypto: Signature, Script, Transaction, PrivateKey } = require 'bitcore-lib'

# Number of random bytes provided by each party
NONCE_SIZE = 16

# Generate random keypairs for Alice and Bob
aliceKeyPair = bitcoin.ECPair.makeRandom()
bobKeyPair = bitcoin.ECPair.makeRandom()

# Alice and Bob each select a random bit
aliceValue = 1
bobValue = 0

aliceRandom = Buffer.alloc(NONCE_SIZE + aliceValue)
crypto.randomFillSync(aliceRandom)

bobRandom = Buffer.alloc(NONCE_SIZE + bobValue)
crypto.randomFillSync(bobRandom)

# The comments bellow follow the stack contents as the Bitcoin Script executes

redeemScriptSource = [
	'OP_2DUP'                                              # [aliceSig, A_rnd, B_rnd]
	'OP_HASH160'                                           # [aliceSig, A_rnd, B_rnd, A_rnd, B_rnd]
	bitcoin.crypto.hash160(bobRandom).toString('hex')      # [aliceSig, A_rnd, B_rnd, A_rnd, HASH160(B_rnd)]
	'OP_EQUALVERIFY'                                       # [aliceSig, A_rnd, B_rnd, A_rnd, HASH160(B_rnd), HASH160(B_rnd)]
	'OP_HASH160'                                           # [aliceSig, A_rnd, B_rnd, A_rnd]
	bitcoin.crypto.hash160(aliceRandom).toString('hex')    # [aliceSig, A_rnd, B_rnd, HASH160(A_rnd)]
	'OP_EQUALVERIFY'                                       # [aliceSig, A_rnd, B_rnd, HASH160(A_rnd), HASH160(A_rnd)]
	'OP_SIZE'                                              # [aliceSig, A_rnd, B_rnd]
	'OP_NIP'                                               # [aliceSig, A_rnd, B_rnd, SIZE(B_rnd)]
	Buffer.from([ NONCE_SIZE ]).toString('hex')            # [aliceSig, A_rnd, SIZE(B_rnd)]
	'OP_NUMEQUAL'                                          # [aliceSig, A_rnd, SIZE(B_rnd), NONCE_SIZE]
	'OP_SWAP'                                              # [aliceSig, A_rnd, B_val]
	'OP_SIZE'                                              # [aliceSig, B_val, A_rnd]
	'OP_NIP'                                               # [aliceSig, B_val, A_rnd, SIZE(A_rnd)]
	Buffer.from([ NONCE_SIZE ]).toString('hex')            # [aliceSig, B_val, SIZE(A_rnd)]
	'OP_NUMEQUAL'                                          # [aliceSig, B_val, SIZE(A_rnd), NONCE_SIZE]
	'OP_NUMEQUAL'                                          # [aliceSig, B_val, A_val]
	'OP_IF'                                                # [aliceSig, B_val === A_val ? 1 : 0]
	aliceKeyPair.getPublicKeyBuffer().toString('hex')      # [aliceSig]
	'OP_ELSE'                                              # [aliceSig, A_pub]
	bobKeyPair.getPublicKeyBuffer().toString('hex')
	'OP_ENDIF'                                             # [bobSig, B_pub]
	'OP_CHECKSIG'                                          # [aliceSig, ]
].join(' ')

redeemScript = bitcoin.script.fromASM(redeemScriptSource)

p2shScriptPub = bitcoin.script.fromASM("OP_HASH160 #{bitcoin.crypto.hash160(redeemScript).toString('hex')} OP_EQUAL")

p2shAddress = bitcoin.address.fromOutputScript(p2shScriptPub)

console.log('Alice')
console.log('    Private Key:', aliceKeyPair.toWIF())
console.log('          Value:', aliceValue)
console.log('         Buffer:', aliceRandom.toString('hex'))
console.log('     Commitment:', bitcoin.crypto.hash160(aliceRandom).toString('hex'))
console.log('Bob')
console.log('    Private Key:', bobKeyPair.toWIF())
console.log('          Value:', bobValue)
console.log('         Buffer:', bobRandom.toString('hex'))
console.log('     Commitment:', bitcoin.crypto.hash160(bobRandom).toString('hex'))
console.log('')
console.log('Funding address:', p2shAddress.toString())
console.log('')

# Assume a UTXO exists that sends 1BTC to the P2SH address calculated above.
# When this runs in production, this UTXO will have inputs from Alice and Bob,
# which is how they place their bets.
p2shUtxoWith1BTC = new Transaction.UnspentOutput(
	txId: 'a477af6b2667c29670467e4e0728b685ee07b240235771862318e29ddbe58458'
	outputIndex: 0
	script: Script.fromBuffer(p2shScriptPub)
	satoshis: 1e8
)

# Calculate who won
if aliceValue is bobValue
	console.log('Alice wins')
	winnerKeyPair = PrivateKey.fromWIF(aliceKeyPair.toWIF())
else
	console.log('Bob wins')
	winnerKeyPair = PrivateKey.fromWIF(bobKeyPair.toWIF())

# Now let's create a transaction that tries to spend the bet
tx = new Transaction()
.from(p2shUtxoWith1BTC)
.to(winnerKeyPair.toAddress(), 1e8)

# Sign the transaction with Alice's private key
sigtype = Signature.SIGHASH_ALL
signature = Transaction.Sighash.sign(tx, winnerKeyPair, sigtype, 0, Script.fromBuffer(redeemScript))
signatureBuffer = Buffer.concat([ signature.toDER(), Buffer.from([ sigtype ]) ])

# Construct the sigScript containing the serialised redeemScript, the two
# random inputs and Alice's signature
p2shScriptSig = Script()
.add(signatureBuffer)
.add(aliceRandom)
.add(bobRandom)
.add(redeemScript)

interpreter = Script.Interpreter()
flags = Script.Interpreter.SCRIPT_VERIFY_P2SH
verified = interpreter.verify(p2shScriptSig, Script.fromBuffer(p2shScriptPub), tx, 0, flags)

console.log('Verifying spending transaction:', verified, interpreter.errstr)
