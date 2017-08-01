crypto = require 'crypto'

_ = require 'lodash'
rp = require 'request-promise'
Big = require 'big.js'
low = require 'lowdb'
colors = require 'colors/safe'
inquirer = require 'inquirer'
bitcoin = require 'bitcoinjs-lib'
Promise = require 'bluebird'
{ blockexplorer } = require('blockchain.info')

coinflip = require './coinflip'

NONCE_SIZE = 16

SATOSHIS_PER_BYTE = 260
P2PKH_SCRIPT_SIZE = 73 + 34; # sigsize (1 + 72) + pubkey (1 + 33)
OUTPUT_SIZE = 80; # this is just an estimate

statePath = '.state'

if process.env.PLAYER
	statePath += "-#{process.env.PLAYER}"

if process.env.TESTNET?
	console.log(colors.bold(colors.blue("""
	***********************************
	*                                 *
	*   YOU ARE PLAYING IN TESTNET    *
	*                                 *
	***********************************
	""")))
	base = 'https://testnet.blockexplorer.com'
	network = bitcoin.networks.testnet
	statePath += '-testnet'
else
	base = 'https://blockexplorer.com'
	network = bitcoin.networks.bitcoin

state = low("#{statePath}.json")

getUTXOs = (addr) ->
	rp("#{base}/api/addr/#{addr}/utxo", json: true)
	.then (utxos) ->
		balance = 0
		for {satoshis} in utxos
			balance += satoshis
		return { utxos, balance }

state.defaults({
	privateKey: null
	games: []
}).write()

utxos = []
balance = 0
keyPair = null
address = null

initKeyPair = ->
	privateKey = state.get('privateKey').value()
	if privateKey is null
		console.log('Creating new wallet..')
		keyPair = bitcoin.ECPair.makeRandom(network: network)
		state.set('privateKey', keyPair.toWIF()).write()
	else
		keyPair = bitcoin.ECPair.fromWIF(privateKey, network)
		console.log('Loaded wallet from disk')

	address = keyPair.getAddress()
	console.log('Your address is:', address)

createGame = ->
	game =
		opponent:
			name: 'Bob'
			address: null
			commit: null
			amount: 0
		state: 'new'
		value: 0
		commit: null
		nonce: null
		amount: 0

	opponentBalance = 0

	questions = [
		{
			name: 'opponent.name'
			message: 'Who are you playing with?'
			default: game.opponent.name
		},
		{
			name: 'amount'
			message: 'How much will you bet? (BTC)'
			filter: Big
			default: Big(balance).div(1e8)
			validate: (btc) ->
				sha = Number(btc.mul(1e8))
				if sha <= 0
					return 'The amount should be greater than zero'
				if sha > balance
					return "You don't have enough funds for this bet"

				game.amount = sha
				return true
		},
		{
			type: 'list'
			name: 'value'
			message: 'Heads or Tails?'
			choices: _.shuffle([ 'Heads', 'Tails' ])
			filter: (side) ->
				value = if side is 'Heads' then 0 else 1

				buf = Buffer.allocUnsafe(NONCE_SIZE + value)
				crypto.randomFillSync(buf)

				commit = bitcoin.crypto.hash160(buf).toString('hex')

				game.commit = commit
				game.nonce = buf.toString('hex')
				game.value = value

				return value
		},
		{
			name: 'opponent.address'
			message: (answers) ->
				console.log("Send this info to #{answers.opponent.name}:")
				console.log('Address:', address)
				console.log('Amount:', Big(game.amount).div(1e8).toString())
				console.log('Commitment:', game.commit)
				return "What is #{answers.opponent.name}'s bitcoin address?"
			validate: (addr) ->
				try
					bitcoin.address.fromBase58Check(addr)
				catch
					return 'Invalid bitcoin address'

				getUTXOs(addr)
				.then ({balance}) ->
					opponentBalance = balance
					return true
		},
		{
			name: 'opponent.amount'
			message: ({opponent}) -> "How much will #{opponent.name} bet? (BTC)"
			default: (ans) -> ans.amount
			filter: Big
			validate: (btc, ans) ->
				sha = Number(btc.mul(1e8))
				if sha <= 0
					return 'The amount should be greater than zero'
				if sha > opponentBalance
					return "#{ans.opponent.name} doen't have enough funds for this bet"

				game.opponent.amount = sha
				return true
		},
		{
			name: 'opponent.commit'
			message: ({opponent}) ->"What is #{opponent.name}'s commitment?"
			validate: (commit) ->
				buf = Buffer.from(commit, 'hex')
				if buf.length isnt 20
					return 'Invalid commitment'
				return true
		},
	]
	inquirer.prompt(questions)
	.then (answers) ->
		game.opponent.name = answers.opponent.name
		game.opponent.commit = answers.opponent.commit
		game.opponent.address = answers.opponent.address
		console.log('Saving game state')
		state.get('games').push(game).write()
		return game

chooseGame = ->
	games = state.get('games').value()

	if games.length is 0
		console.log('> You have no ongoing games')
	else
		console.log(colors.green('> You have', games.length, 'ongoing games'))

	inquirer.prompt([
		{
			type: 'confirm'
			name: 'newGame'
			message: 'Would you like to start a new game?'
			default: true
		}
	]).then ({newGame}) ->
		if newGame
			return createGame()
		else if games.length > 0
			gameChoices = _.keyBy(games, (g) -> "#{g.opponent.name} - #{Big(g.amount).div(1e8)}BTC")

			questions = [
				{
					type: 'list'
					name: 'game'
					message: 'Choose game to resume'
					choices: Object.keys(gameChoices)
					filter: (choice) -> gameChoices[choice]
				}
			]
			return inquirer.prompt(questions).then((answer) -> answer.game)
		else
			throw new Error()

finalizeGame = (game, ourUTXOs, opponentUTXOs) ->
	p2shAddress = coinflip.createP2SHAddr(game.commit, game.opponent.commit, address, game.opponent.address, network)
	console.log('Will send to', p2shAddress)

	# deterministically decide who will generate the tx and who will wait
	shouldCreateTx = game.commit > game.opponent.commit

	if shouldCreateTx
		txb = new bitcoin.TransactionBuilder(network)

		ourFees = 1.5 * SATOSHIS_PER_BYTE * OUTPUT_SIZE
		ourSum = 0
		for {txid, vout, satoshis} in ourUTXOs
			if ourSum >= game.amount + ourFees
				break
			txb.addInput(txid, vout)
			ourSum += satoshis
			ourFees += SATOSHIS_PER_BYTE * P2PKH_SCRIPT_SIZE

		opponentFees = 1.5 * SATOSHIS_PER_BYTE * OUTPUT_SIZE
		opponentSum = 0
		for {txid, vout, satoshis} in opponentUTXOs
			if opponentSum >= game.opponent.amount + opponentFees
				break
			txb.addInput(txid, vout)
			opponentSum += satoshis
			opponentFees += SATOSHIS_PER_BYTE * P2PKH_SCRIPT_SIZE

		txb.addOutput(p2shAddress, game.amount + game.opponent.amount)

		if ourSum > game.amount + ourFees
			txb.addOutput(address, ourSum - game.amount - ourFees)

		if opponentSum > game.opponent.amount + opponentFees
			txb.addOutput(game.opponent.address, opponentSum - game.opponent.amount - opponentFees)

		# sign our inputs
		for { hash, index }, vin in txb.tx.ins
			txHash = Buffer.from(hash).reverse().toString('hex')
			if  _.find(ourUTXOs, txid: txHash, vout: index)?
				txb.sign(vin, keyPair)

		tx = txb.buildIncomplete().toHex()
		console.log(colors.green("Send this to #{game.opponent.name}:"), tx)
	else # wait for signed tx
		inquirer.prompt(
			name: 'input'
			message: "Enter #{game.opponent.name}'s signed transaction"
		)
		.then ({input}) ->
			tx = bitcoin.Transaction.fromHex(input)
			txb = bitcoin.TransactionBuilder.fromTransaction(tx, network)

			# sign our inputs
			for { hash, index }, vin in txb.tx.ins
				txHash = Buffer.from(hash).reverse().toString('hex')
				if  _.find(ourUTXOs, txid: txHash, vout: index)?
					txb.sign(vin, keyPair)

			tx = txb.build().toHex()
			console.log(colors.green("Transaction ready:"), tx)
		
main = ->
	console.log(colors.bold('- Welcome to bitcoin coinflip!'))
	initKeyPair()

	getUTXOs(address)
	.then (info) ->
		utxos = info.utxos
		balance = info.balance
	.then(chooseGame)
	.then (game) ->
		Promise.all([ game, getUTXOs(address).get('utxos'), getUTXOs(game.opponent.address).get('utxos') ])
	.spread(finalizeGame)
	.catch (e) ->
		console.log(e)
		console.log('Goodbye')
		process.exit()

main()
